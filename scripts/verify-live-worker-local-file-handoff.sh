#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
NAMESPACE="${NAMESPACE:-kestra-dev}"
LIVE_DOMAIN_NAME="${LIVE_DOMAIN_NAME:-}"
LIVE_GKE_SUBDOMAIN="${LIVE_GKE_SUBDOMAIN:-k8s}"
FLOW_NAMESPACE="playground.worker_routing"
FLOW_ID="verify_worker_local_file_handoff"

for command in curl gcloud jq kubectl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: ${command}" >&2
    exit 1
  fi
done

if [[ -z "$PROJECT_ID" || -z "$LIVE_DOMAIN_NAME" ]]; then
  echo "Missing PROJECT_ID/GCP_PROJECT_ID or LIVE_DOMAIN_NAME." >&2
  exit 1
fi

# shellcheck source=scripts/lib/gke-auth.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gke-auth.sh"
ensure_gke_kubectl_auth

secret_value() {
  gcloud secrets versions access latest --project="$PROJECT_ID" --secret="$1"
}

wait_for_ui() {
  local url="$1"
  local username="$2"
  local password="$3"

  for _ in {1..120}; do
    if curl --fail --silent --show-error --max-time 20 \
      --user "${username}:${password}" \
      "${url%/}/" >/dev/null; then
      return 0
    fi
    sleep 10
  done

  echo "Kestra UI did not become ready: ${url}" >&2
  return 1
}

start_execution() {
  local url="$1"
  local username="$2"
  local password="$3"
  local write_file="$4"

  curl --fail --silent --show-error \
    --user "${username}:${password}" \
    --request POST \
    --form "write_file=${write_file}" \
    "${url%/}/api/v1/main/executions/${FLOW_NAMESPACE}/${FLOW_ID}" \
    | jq -er '.id'
}

wait_for_execution_state() {
  local url="$1"
  local username="$2"
  local password="$3"
  local execution_id="$4"
  local expected_state="$5"
  local execution_json=""
  local state=""

  for _ in {1..180}; do
    execution_json="$(
      curl --fail --silent --show-error \
        --user "${username}:${password}" \
        "${url%/}/api/v1/main/executions/${execution_id}"
    )"
    state="$(jq -r '.state.current // empty' <<<"${execution_json}")"
    case "$state" in
      SUCCESS | FAILED | KILLED | CANCELLED | WARNING)
        if [[ "$state" != "$expected_state" ]]; then
          echo "Execution ${execution_id} finished with ${state}; expected ${expected_state}." >&2
          jq -r '.taskRunList // []' <<<"${execution_json}" >&2
          return 1
        fi
        printf '%s\n' "$execution_json"
        return 0
        ;;
    esac
    sleep 5
  done

  echo "Execution ${execution_id} did not finish. Last state: ${state:-unknown}." >&2
  return 1
}

task_state() {
  local execution_json="$1"
  local task_id="$2"

  jq -r --arg task_id "$task_id" '
    [.taskRunList // [] | .[] | select(.taskId == $task_id) | .state.current][-1] // ""
  ' <<<"${execution_json}"
}

task_worker_id() {
  local execution_json="$1"
  local task_id="$2"

  jq -r --arg task_id "$task_id" '
    [
      .taskRunList // []
      | .[]
      | select(.taskId == $task_id)
      | (.workerId // .worker.id // .attempts[-1].workerId // "")
    ][-1] // ""
  ' <<<"${execution_json}"
}

execution_log_messages() {
  local url="$1"
  local username="$2"
  local password="$3"
  local execution_id="$4"

  curl --fail --silent --show-error \
    --user "${username}:${password}" \
    "${url%/}/api/v1/main/logs/${execution_id}" \
    | jq -r '(if type == "array" then . else (.results // []) end)[] | .message // ""'
}

gke_url="https://${LIVE_GKE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
gke_username="$(secret_value kestra-dev-gke-kestra-basic-auth-username)"
gke_password="$(secret_value kestra-dev-gke-kestra-basic-auth-password)"
batch_db_username="$(
  kubectl -n "$NAMESPACE" get secret kestra-secrets -o json \
    | jq -r '.data.ENV_BATCH_DB_USERNAME | @base64d'
)"
batch_db_password="$(
  kubectl -n "$NAMESPACE" get secret kestra-secrets -o json \
    | jq -r '.data.ENV_BATCH_DB_PASSWORD | @base64d'
)"

gcloud container clusters get-credentials kestra-dev \
  --region "$REGION" \
  --project "$PROJECT_ID"

export KESTRA_BASIC_AUTH_USERNAME="$gke_username"
export KESTRA_BASIC_AUTH_PASSWORD="$gke_password"

wait_for_ui "$gke_url" "$gke_username" "$gke_password"
scripts/register-flows.sh "$gke_url" kestra/flows-worker-routing

success_id="$(start_execution "$gke_url" "$gke_username" "$gke_password" true)"
echo "${FLOW_ID} success case: ${success_id}"
success_json="$(wait_for_execution_state "$gke_url" "$gke_username" "$gke_password" "$success_id" SUCCESS)"

if [[ "$(task_state "$success_json" write_worker_local_file)" != "SUCCESS" \
  || "$(task_state "$success_json" read_worker_local_file)" != "SUCCESS" \
  || "$(task_state "$success_json" register_worker_local_file)" != "SUCCESS" ]]; then
  echo "Expected the writer, reader, and database registration tasks to succeed." >&2
  exit 1
fi

writer_worker="$(task_worker_id "$success_json" write_worker_local_file)"
reader_worker="$(task_worker_id "$success_json" read_worker_local_file)"
database_worker="$(task_worker_id "$success_json" register_worker_local_file)"
if [[ -z "$writer_worker" || "$writer_worker" != "$reader_worker" || "$writer_worker" != "$database_worker" ]]; then
  echo "Expected writer, reader, and database registration on one worker, got writer=${writer_worker:-missing} reader=${reader_worker:-missing} database=${database_worker:-missing}." >&2
  exit 1
fi

if ! kubectl -n "$NAMESPACE" logs statefulset/kestra-gke-worker-large -c kestra-worker \
  | grep -F "workerId=${writer_worker}, workerGroup=gke-large" >/dev/null; then
  echo "Worker ${writer_worker} was not confirmed as the gke-large StatefulSet member." >&2
  exit 1
fi

success_logs="$(execution_log_messages "$gke_url" "$gke_username" "$gke_password" "$success_id")"
for marker in "local_handoff=written" "local_handoff=read"; do
  if ! grep -Fq "$marker" <<<"${success_logs}"; then
    echo "Missing success marker: ${marker}" >&2
    exit 1
  fi
done

registered_value="$(
  kubectl -n "$NAMESPACE" exec statefulset/kestra-postgres -- \
    env PGPASSWORD="$batch_db_password" \
    psql --username="$batch_db_username" --dbname=ecommerce_ops --tuples-only --no-align \
    --command "SELECT handoff_value FROM worker_local_handoffs WHERE execution_id = '${success_id}';"
)"
expected_value="orders-ready-${success_id}"
if [[ "$registered_value" != "$expected_value" ]]; then
  echo "Expected database value ${expected_value}, got ${registered_value:-missing}." >&2
  exit 1
fi

missing_id="$(start_execution "$gke_url" "$gke_username" "$gke_password" false)"
echo "${FLOW_ID} missing-file case: ${missing_id}"
missing_json="$(wait_for_execution_state "$gke_url" "$gke_username" "$gke_password" "$missing_id" FAILED)"
if [[ "$(task_state "$missing_json" read_worker_local_file)" != "FAILED" ]]; then
  echo "Expected the reader to fail when the producer is skipped." >&2
  exit 1
fi
missing_logs="$(execution_log_messages "$gke_url" "$gke_username" "$gke_password" "$missing_id")"
if ! grep -Fq "local_handoff=missing" <<<"${missing_logs}"; then
  echo "Missing the expected absent-file error marker." >&2
  exit 1
fi

missing_row_count="$(
  kubectl -n "$NAMESPACE" exec statefulset/kestra-postgres -- \
    env PGPASSWORD="$batch_db_password" \
    psql --username="$batch_db_username" --dbname=ecommerce_ops --tuples-only --no-align \
    --command "SELECT count(*) FROM worker_local_handoffs WHERE execution_id = '${missing_id}';"
)"
if [[ "$missing_row_count" != "0" ]]; then
  echo "The missing-file execution unexpectedly registered a database row." >&2
  exit 1
fi

kubectl -n "$NAMESPACE" get statefulset kestra-gke-worker-large >/dev/null
kubectl -n "$NAMESPACE" get pvc worker-local-kestra-gke-worker-large-0 >/dev/null

echo "Worker-local file handoff verification succeeded."
echo "success_execution=${success_id}"
echo "missing_file_execution=${missing_id}"
echo "worker=${writer_worker}"
echo "database_value=${registered_value}"
