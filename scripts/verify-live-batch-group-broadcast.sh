#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
NAMESPACE="${NAMESPACE:-kestra-dev}"
BUSINESS_DATE="${1:-${BUSINESS_DATE:-2026-06-25}}"
LIVE_DOMAIN_NAME="${LIVE_DOMAIN_NAME:-}"
LIVE_GKE_SUBDOMAIN="${LIVE_GKE_SUBDOMAIN:-k8s}"
FLOW_NAMESPACE="playground.worker_routing"
FLOW_ID="verify_batch_group_broadcast"
TASK_ID="broadcast_to_batch_group"
WORKER_DEPLOYMENT="${BROADCAST_WORKER_DEPLOYMENT:-kestra-gke-worker-small}"
WORKER_GROUP="${BROADCAST_WORKER_GROUP:-gke-small}"
WORKER_CONTAINER="${BROADCAST_WORKER_CONTAINER:-kestra-worker}"
EXPECTED_WORKERS="${BROADCAST_WORKER_REPLICAS:-2}"
ORIGINAL_REPLICAS=""

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for command in curl gcloud jq kubectl; do
  require_command "${command}"
done

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Missing required environment variable: PROJECT_ID or GCP_PROJECT_ID" >&2
  exit 1
fi

if [[ -z "${LIVE_DOMAIN_NAME}" ]]; then
  echo "Missing required environment variable: LIVE_DOMAIN_NAME" >&2
  exit 1
fi

if ! [[ "${EXPECTED_WORKERS}" =~ ^[2-9][0-9]*$ ]]; then
  echo "BROADCAST_WORKER_REPLICAS must be an integer of at least 2." >&2
  exit 1
fi

secret_value() {
  local secret_name="$1"
  gcloud secrets versions access latest --project="${PROJECT_ID}" --secret="${secret_name}"
}

restore_worker_replicas() {
  local status=$?

  trap - EXIT

  if [[ -n "${ORIGINAL_REPLICAS}" ]]; then
    echo "Restoring ${WORKER_DEPLOYMENT} to ${ORIGINAL_REPLICAS} replica(s)."
    kubectl -n "${NAMESPACE}" scale deployment "${WORKER_DEPLOYMENT}" \
      --replicas="${ORIGINAL_REPLICAS}" >/dev/null || true
  fi

  exit "${status}"
}

wait_for_ui() {
  local url="$1"
  local username="$2"
  local password="$3"

  for _ in {1..120}; do
    if curl --fail --silent --show-error --max-time 20 \
      -u "${username}:${password}" \
      "${url%/}/" >/dev/null; then
      return 0
    fi
    sleep 10
  done

  echo "Kestra UI did not become ready: ${url}" >&2
  return 1
}

wait_for_execution() {
  local url="$1"
  local username="$2"
  local password="$3"
  local execution_id="$4"
  local execution_json=""
  local state=""

  for _ in {1..120}; do
    execution_json="$(
      curl --fail --silent --show-error --max-time 20 \
        -u "${username}:${password}" \
        "${url%/}/api/v1/main/executions/${execution_id}"
    )"
    state="$(jq -r '.state.current // empty' <<<"${execution_json}")"

    case "${state}" in
      SUCCESS)
        printf '%s\n' "${execution_json}"
        return 0
        ;;
      FAILED | KILLED | CANCELLED | WARNING)
        echo "Broadcast verification execution ${execution_id} ended with state ${state}." >&2
        jq -r '.taskRunList // []' <<<"${execution_json}" >&2
        return 1
        ;;
    esac

    sleep 5
  done

  echo "Broadcast verification execution ${execution_id} did not finish." >&2
  return 1
}

wait_for_worker_registrations() {
  local pod=""
  local all_connected=""

  for _ in {1..120}; do
    all_connected=true
    for pod in "$@"; do
      if ! kubectl -n "${NAMESPACE}" logs "${pod}" -c "${WORKER_CONTAINER}" \
        | grep -F "Connected to controller:" \
        | grep -F "workerGroup=${WORKER_GROUP}" >/dev/null; then
        all_connected=false
        break
      fi
    done

    if [[ "${all_connected}" == true ]]; then
      return 0
    fi
    sleep 5
  done

  echo "Not all ${WORKER_GROUP} pods registered with the controller." >&2
  return 1
}

gke_url="https://${LIVE_GKE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
gke_username="$(secret_value kestra-dev-gke-kestra-basic-auth-username)"
gke_password="$(secret_value kestra-dev-gke-kestra-basic-auth-password)"

gcloud container clusters get-credentials kestra-dev \
  --region "${REGION}" \
  --project "${PROJECT_ID}"

if ! kubectl -n "${NAMESPACE}" get deployment "${WORKER_DEPLOYMENT}" >/dev/null 2>&1; then
  echo "Missing routed worker deployment: ${WORKER_DEPLOYMENT}" >&2
  exit 1
fi

ORIGINAL_REPLICAS="$(
  kubectl -n "${NAMESPACE}" get deployment "${WORKER_DEPLOYMENT}" \
    -o jsonpath='{.spec.replicas}'
)"
trap restore_worker_replicas EXIT

kubectl -n "${NAMESPACE}" scale deployment "${WORKER_DEPLOYMENT}" \
  --replicas="${EXPECTED_WORKERS}" >/dev/null
kubectl -n "${NAMESPACE}" rollout status deployment/"${WORKER_DEPLOYMENT}" --timeout=10m

# Kubernetes readiness only proves that each worker process is healthy. Restart
# the complete test group after scaling so every pod opens a fresh stream to the
# current controller, then wait for the connection acknowledgement in each pod.
kubectl -n "${NAMESPACE}" rollout restart deployment/"${WORKER_DEPLOYMENT}" >/dev/null
kubectl -n "${NAMESPACE}" rollout status deployment/"${WORKER_DEPLOYMENT}" --timeout=10m

mapfile -t expected_members < <(
  kubectl -n "${NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=kestra-gke-routed-worker,kestra.worker/group=${WORKER_GROUP}" \
    -o json \
    | jq -r '
        .items[]
        | select(.metadata.deletionTimestamp == null)
        | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
        | .metadata.name
      ' \
    | sort -u
)

if [[ "${#expected_members[@]}" -ne "${EXPECTED_WORKERS}" ]]; then
  echo "Expected ${EXPECTED_WORKERS} ready ${WORKER_GROUP} workers, got ${#expected_members[@]}." >&2
  exit 1
fi

wait_for_worker_registrations "${expected_members[@]}"

export KESTRA_BASIC_AUTH_USERNAME="${gke_username}"
export KESTRA_BASIC_AUTH_PASSWORD="${gke_password}"
wait_for_ui "${gke_url}" "${gke_username}" "${gke_password}"
scripts/register-flows.sh "${gke_url}" kestra/flows-worker-routing

response="$(
  NAMESPACE="${FLOW_NAMESPACE}" \
    scripts/run-flow.sh "${FLOW_ID}" "${BUSINESS_DATE}" "${gke_url}"
)"
execution_id="$(jq -er '.id' <<<"${response}")"
echo "${FLOW_ID}: ${execution_id}"
execution_json="$(wait_for_execution "${gke_url}" "${gke_username}" "${gke_password}" "${execution_id}")"

task_run_id="$(
  jq -er --arg task_id "${TASK_ID}" '
    [.taskRunList[] | select(.taskId == $task_id and .state.current == "SUCCESS")][-1].id
  ' <<<"${execution_json}"
)"

outputs_json="$(
  curl --fail --silent --show-error --max-time 20 \
    -u "${gke_username}:${gke_password}" \
    "${gke_url%/}/api/v1/main/outputs/${execution_id}/${task_run_id}"
)"
output_worker_count="$(jq -er 'length' <<<"${outputs_json}")"

if [[ "${output_worker_count}" -ne "${EXPECTED_WORKERS}" ]]; then
  echo "Expected ${EXPECTED_WORKERS} worker-keyed task outputs, got ${output_worker_count}." >&2
  jq -r 'keys' <<<"${outputs_json}" >&2
  exit 1
fi

logs_json="$(
  curl --fail --silent --show-error --max-time 20 \
    -u "${gke_username}:${gke_password}" \
    "${gke_url%/}/api/v1/main/logs/${execution_id}"
)"
logged_members=()
for expected_member in "${expected_members[@]}"; do
  if jq -e --arg task_id "${TASK_ID}" --arg marker "batch_group_member=${expected_member}" '
    (if type == "array" then . else (.results // []) end)
    | any(
        .[];
        .taskId == $task_id
        and ((.message // "") | split("\n") | any(. == $marker))
      )
  ' <<<"${logs_json}" >/dev/null; then
    logged_members+=("${expected_member}")
  fi
done

if [[ "${logged_members[*]}" != "${expected_members[*]}" ]]; then
  echo "Broadcast members did not match the ready batch-group members." >&2
  echo "Expected: ${expected_members[*]}" >&2
  echo "Logged: ${logged_members[*]}" >&2
  exit 1
fi

echo "Batch-group broadcast execution ${execution_id} succeeded on ${output_worker_count} workers."
printf 'member=%s\n' "${logged_members[@]}"
mapfile -t output_worker_ids < <(jq -r 'keys[]' <<<"${outputs_json}")
printf 'output_worker_id=%s\n' "${output_worker_ids[@]}"
