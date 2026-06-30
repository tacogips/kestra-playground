#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
LIVE_DOMAIN_NAME="${LIVE_DOMAIN_NAME:-}"
LIVE_GKE_SUBDOMAIN="${LIVE_GKE_SUBDOMAIN:-k8s}"
BUSINESS_DATE="${1:-${BUSINESS_DATE:-2026-06-25}}"
FLOW_NAMESPACE="playground.operation_demo"
FLOW_ID="resource_probe_routed_workers"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command curl
require_command gcloud
require_command jq

if [[ -z "$PROJECT_ID" || -z "$LIVE_DOMAIN_NAME" ]]; then
  echo "Missing PROJECT_ID/GCP_PROJECT_ID or LIVE_DOMAIN_NAME" >&2
  exit 1
fi

secret_value() {
  gcloud secrets versions access latest --project="${PROJECT_ID}" --secret="$1"
}

wait_for_execution() {
  local url="$1" username="$2" password="$3" execution_id="$4"
  local execution_json state

  for _ in {1..180}; do
    execution_json="$(curl --fail --silent --show-error -u "${username}:${password}" "${url%/}/api/v1/main/executions/${execution_id}")"
    state="$(jq -r '.state.current // empty' <<<"${execution_json}")"
    case "${state}" in
      SUCCESS)
        printf '%s\n' "${execution_json}"
        return 0
        ;;
      FAILED | KILLED | WARNING)
        echo "Execution ${execution_id} finished with ${state}" >&2
        jq -r '.taskRunList // []' <<<"${execution_json}" >&2
        return 1
        ;;
    esac
    sleep 5
  done

  echo "Execution ${execution_id} did not finish" >&2
  return 1
}

gke_url="https://${LIVE_GKE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
gke_username="$(secret_value kestra-dev-gke-kestra-basic-auth-username)"
gke_password="$(secret_value kestra-dev-gke-kestra-basic-auth-password)"

export KESTRA_BASIC_AUTH_USERNAME="${gke_username}"
export KESTRA_BASIC_AUTH_PASSWORD="${gke_password}"

scripts/register-flows.sh "${gke_url}" kestra/flows-operation-demo/routed-worker
response="$(NAMESPACE="${FLOW_NAMESPACE}" scripts/run-flow.sh "${FLOW_ID}" "${BUSINESS_DATE}" "${gke_url}")"
execution_id="$(jq -er '.id' <<<"${response}")"
echo "${FLOW_ID}: ${execution_id}"
execution_json="$(wait_for_execution "${gke_url}" "${gke_username}" "${gke_password}" "${execution_id}")"

jq -r '
  "Task run summary:",
  (["taskId", "state", "workerId"] | @tsv),
  ((.taskRunList // [])[] | [(.taskId // ""), (.state.current // ""), (.workerId // .worker.id // "")] | @tsv)
  ' <<<"${execution_json}"

logs_json="$(
  curl --fail --silent --show-error \
  -u "${gke_username}:${gke_password}" \
    "${gke_url%/}/api/v1/main/logs/${execution_id}"
)"

jq -e '
  ((if type == "array" then . else (.results // []) end))
  | any(.taskId == "batch_1_on_gce_a" and (.message // "") == "hostname=kestra-dev-gce-a")
' <<<"${logs_json}" >/dev/null
jq -e '
  ((if type == "array" then . else (.results // []) end))
  | any(.taskId == "batch_1_on_gce_a" and (.message // "") == "worker_group=gce-a")
' <<<"${logs_json}" >/dev/null
jq -e '
  ((if type == "array" then . else (.results // []) end))
  | any(.taskId == "batch_2_on_gce_b" and (.message // "") == "hostname=kestra-dev-gce-b")
' <<<"${logs_json}" >/dev/null
jq -e '
  ((if type == "array" then . else (.results // []) end))
  | any(.taskId == "batch_2_on_gce_b" and (.message // "") == "worker_group=gce-b")
' <<<"${logs_json}" >/dev/null

jq -r '((if type == "array" then . else (.results // []) end))[] | [.taskId, .level, .message] | @tsv' \
  <<<"${logs_json}"
