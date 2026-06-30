#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
LIVE_DOMAIN_NAME="${LIVE_DOMAIN_NAME:-}"
LIVE_GKE_SUBDOMAIN="${LIVE_GKE_SUBDOMAIN:-k8s}"
NAMESPACE="${NAMESPACE:-kestra-dev}"
BUSINESS_DATE="${1:-${BUSINESS_DATE:-2026-06-25}}"
FLOW_NAMESPACE="playground.operation_demo"
FLOW_ID="resource_probe_gke_pod_resources"

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
    if ! execution_json="$(curl --fail --silent --show-error -u "${username}:${password}" "${url%/}/api/v1/main/executions/${execution_id}")"; then
      sleep 5
      continue
    fi
    if ! state="$(jq -er '.state.current // empty' <<<"${execution_json}" 2>/dev/null)"; then
      echo "Execution status response was not a Kestra execution JSON document." >&2
      head -c 500 <<<"${execution_json}" >&2
      echo >&2
      return 1
    fi
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

wait_for_ui() {
  local url="$1" username="$2" password="$3"

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

pod_resources_json() {
  local execution_id="$1"
  local selector="app.kubernetes.io/name=kestra-operation-demo,kestra-playground.tacogips.io/execution=${execution_id}"
  local pods_json
  local small_count
  local large_count

  for _ in {1..30}; do
    pods_json="$(kubectl -n "${NAMESPACE}" get pods -l "${selector}" -o json)"
    small_count="$(
      jq -r '[.items[] | select(.metadata.labels["kestra-playground.tacogips.io/resource-class"] == "small")] | length' \
        <<<"${pods_json}"
    )"
    large_count="$(
      jq -r '[.items[] | select(.metadata.labels["kestra-playground.tacogips.io/resource-class"] == "large")] | length' \
        <<<"${pods_json}"
    )"
    if [[ "${small_count}" -ge 1 && "${large_count}" -ge 1 ]]; then
      printf '%s\n' "${pods_json}"
      return 0
    fi
    sleep 2
  done

  echo "Expected one small and one large operation demo pod for execution ${execution_id}." >&2
  kubectl -n "${NAMESPACE}" get pods -l "${selector}" -o wide >&2 || true
  return 1
}

assert_pod_resources() {
  local pods_json="$1" resource_class="$2" expected="$3"
  local actual

  actual="$(
    jq -r --arg resource_class "${resource_class}" '
      [
        .items[]
        | select(.metadata.labels["kestra-playground.tacogips.io/resource-class"] == $resource_class)
        | .spec.containers[0].resources
        | [.requests.cpu, .requests.memory, .limits.cpu, .limits.memory]
      ]
      | unique
      | .[]
      | @tsv
    ' <<<"${pods_json}"
  )"

  if [[ "${actual}" != "${expected}" ]]; then
    echo "Unexpected ${resource_class} pod resources: ${actual:-missing}" >&2
    jq -r '.items[] | {name: .metadata.name, labels: .metadata.labels, resources: .spec.containers[0].resources}' \
      <<<"${pods_json}" >&2
    return 1
  fi
}

print_pod_resources() {
  local pods_json="$1"

  echo "Created pod resources:"
  jq -r '
    (["name", "resourceClass", "node", "phase", "cpuRequest", "memoryRequest", "cpuLimit", "memoryLimit"] | @tsv),
    (.items[]
      | [
          .metadata.name,
          .metadata.labels["kestra-playground.tacogips.io/resource-class"],
          (.spec.nodeName // ""),
          (.status.phase // ""),
          .spec.containers[0].resources.requests.cpu,
          .spec.containers[0].resources.requests.memory,
          .spec.containers[0].resources.limits.cpu,
          .spec.containers[0].resources.limits.memory
        ]
      | @tsv)
  ' <<<"${pods_json}"
}

print_execution_logs() {
  local url="$1" username="$2" password="$3" execution_id="$4"

  curl --fail --silent --show-error \
    -u "${username}:${password}" \
    "${url%/}/api/v1/main/logs/${execution_id}" \
    | jq -r '((if type == "array" then . else (.results // []) end))[] | [.taskId, .level, .message] | @tsv' \
    || true
}

cleanup_resource_pods() {
  local execution_id="$1"
  local selector="app.kubernetes.io/name=kestra-operation-demo,kestra-playground.tacogips.io/execution=${execution_id}"

  kubectl -n "${NAMESPACE}" delete pods -l "${selector}" --ignore-not-found
}

gke_url="https://${LIVE_GKE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
gke_username="$(secret_value kestra-dev-gke-kestra-basic-auth-username)"
gke_password="$(secret_value kestra-dev-gke-kestra-basic-auth-password)"

gcloud container clusters get-credentials kestra-dev --region "${REGION}" --project "${PROJECT_ID}"
export KESTRA_BASIC_AUTH_USERNAME="${gke_username}"
export KESTRA_BASIC_AUTH_PASSWORD="${gke_password}"

wait_for_ui "${gke_url}" "${gke_username}" "${gke_password}"
scripts/register-flows.sh "${gke_url}" kestra/flows-operation-demo/gke-pod-resources

execution_id=""
cleanup_on_exit() {
  if [[ -n "${execution_id}" ]]; then
    cleanup_resource_pods "${execution_id}" >/dev/null 2>&1 || true
  fi
}
trap cleanup_on_exit EXIT

response="$(
  curl --fail --silent --show-error \
    -u "${gke_username}:${gke_password}" \
    -X POST \
    -F "business_date=${BUSINESS_DATE}" \
    -F "kubernetes_namespace=${NAMESPACE}" \
    "${gke_url%/}/api/v1/main/executions/${FLOW_NAMESPACE}/${FLOW_ID}"
)"
if ! jq -e '.id and .namespace and .flowId' <<<"${response}" >/dev/null 2>&1; then
  echo "Flow execution response was not a Kestra execution JSON document." >&2
  head -c 500 <<<"${response}" >&2
  echo >&2
  exit 1
fi
execution_id="$(jq -er '.id' <<<"${response}")"
echo "${FLOW_ID}: ${execution_id}"
pods_json="$(pod_resources_json "${execution_id}")"

assert_pod_resources "${pods_json}" small $'500m\t512Mi\t1\t1Gi'
assert_pod_resources "${pods_json}" large $'2\t4Gi\t4\t8Gi'
print_pod_resources "${pods_json}"

if ! execution_json="$(wait_for_execution "${gke_url}" "${gke_username}" "${gke_password}" "${execution_id}")"; then
  echo "Kestra execution ${execution_id} did not complete cleanly after pod resources were verified." >&2
  print_execution_logs "${gke_url}" "${gke_username}" "${gke_password}" "${execution_id}" >&2
  exit 1
fi

jq -r '
  "Task run summary:",
  (["taskId", "state", "workerId"] | @tsv),
  ((.taskRunList // [])[] | [(.taskId // ""), (.state.current // ""), (.workerId // .worker.id // "")] | @tsv)
' <<<"${execution_json}"

cleanup_resource_pods "${execution_id}"
trap - EXIT
