#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
NAMESPACE="${NAMESPACE:-kestra-dev}"
BUSINESS_DATE="${1:-${BUSINESS_DATE:-2026-06-25}}"
LIVE_DOMAIN_NAME="${LIVE_DOMAIN_NAME:-}"
LIVE_GKE_SUBDOMAIN="${LIVE_GKE_SUBDOMAIN:-k8s}"
FLOW_NAMESPACE="playground.worker_routing"
FLOW_ID="verify_gke_node_worker_routing"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command curl
require_command gcloud
require_command jq
require_command kubectl

if [[ -z "$PROJECT_ID" ]]; then
  echo "Missing required environment variable: PROJECT_ID or GCP_PROJECT_ID" >&2
  exit 1
fi

if [[ -z "$LIVE_DOMAIN_NAME" ]]; then
  echo "Missing required environment variable: LIVE_DOMAIN_NAME" >&2
  exit 1
fi

secret_value() {
  local secret_name="$1"
  gcloud secrets versions access latest --project="${PROJECT_ID}" --secret="${secret_name}"
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
  local status_url="${url%/}/api/v1/main/executions/${execution_id}"
  local execution_json
  local state=""

  for _ in {1..180}; do
    execution_json="$(
      curl --fail --silent --show-error \
        -u "${username}:${password}" \
        "${status_url}"
    )"
    state="$(jq -r '.state.current // empty' <<<"${execution_json}")"

    case "${state}" in
      SUCCESS)
        printf '%s\n' "${execution_json}"
        return 0
        ;;
      FAILED | KILLED | WARNING)
        echo "Execution ${execution_id} finished with state ${state}." >&2
        jq -r '.taskRunList // []' <<<"${execution_json}" >&2
        return 1
        ;;
    esac

    sleep 5
  done

  echo "Execution ${execution_id} did not finish. Last state: ${state:-unknown}" >&2
  return 1
}

assert_task_success() {
  local execution_json="$1"
  local task_id="$2"
  local state

  state="$(
    jq -r --arg task_id "${task_id}" '
      (.taskRunList // [])
      | map(select(.taskId == $task_id))
      | last
      | .state.current // ""
    ' <<<"${execution_json}"
  )"

  if [[ "${state}" != "SUCCESS" ]]; then
    echo "Expected task ${task_id} to be SUCCESS, got ${state:-missing}." >&2
    jq -r '.taskRunList // []' <<<"${execution_json}" >&2
    exit 1
  fi
}

task_worker_id() {
  local execution_json="$1"
  local task_id="$2"

  jq -r --arg task_id "${task_id}" '
    (.taskRunList // [])
    | map(select(.taskId == $task_id))
    | last
    | (.workerId // .worker.id // .attempts[-1].workerId // "")
  ' <<<"${execution_json}"
}

print_execution_logs() {
  local url="$1"
  local username="$2"
  local password="$3"
  local execution_id="$4"

  curl --fail --silent --show-error \
    -u "${username}:${password}" \
    "${url%/}/api/v1/main/logs/${execution_id}" \
    | jq -r '
        "Kestra execution logs:",
        (((if type == "array" then . else (.results // []) end))[]
          | [
              (.taskId // ""),
              (.level // ""),
              (.message // "")
            ]
          | @tsv)
      '
}

gke_url="https://${LIVE_GKE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
gke_username="$(secret_value kestra-dev-gke-kestra-basic-auth-username)"
gke_password="$(secret_value kestra-dev-gke-kestra-basic-auth-password)"

gcloud container clusters get-credentials kestra-dev \
  --region "${REGION}" \
  --project "${PROJECT_ID}"

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

assert_task_success "${execution_json}" run_on_gke_small
assert_task_success "${execution_json}" run_on_gke_large

worker_small="$(task_worker_id "${execution_json}" run_on_gke_small)"
worker_large="$(task_worker_id "${execution_json}" run_on_gke_large)"
if [[ -z "${worker_small}" || -z "${worker_large}" ]]; then
  echo "Expected both GKE routed tasks to report worker IDs." >&2
  exit 1
fi

echo "GKE node worker routing execution ${execution_id} succeeded."
jq -r '
  "Task run summary:",
  (["taskId", "state", "workerId"] | @tsv),
  ((.taskRunList // [])[]
    | [
        (.taskId // ""),
        (.state.current // ""),
        (.workerId // .worker.id // .attempts[-1].workerId // "")
      ]
    | @tsv)
' <<<"${execution_json}"

print_execution_logs "${gke_url}" "${gke_username}" "${gke_password}" "${execution_id}"

echo "Kubernetes worker pod placement:"
kubectl -n "${NAMESPACE}" get pods \
  -l app.kubernetes.io/name=kestra-gke-routed-worker \
  -o custom-columns=NAME:.metadata.name,GROUP:.metadata.labels.kestra\\.worker/group,NODE:.spec.nodeName,PHASE:.status.phase

echo "Recent GKE routed worker logs:"
kubectl -n "${NAMESPACE}" logs deployment/kestra-gke-worker-small -c kestra-worker --tail=80
kubectl -n "${NAMESPACE}" logs deployment/kestra-gke-worker-large -c kestra-worker --tail=80
