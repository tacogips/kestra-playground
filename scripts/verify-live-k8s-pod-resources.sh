#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
LIVE_DOMAIN_NAME="${LIVE_DOMAIN_NAME:-}"
LIVE_GKE_SUBDOMAIN="${LIVE_GKE_SUBDOMAIN:-k8s}"
NAMESPACE="${NAMESPACE:-kestra-dev}"
FLOW_NAMESPACE="playground.k8s_pod_resources"
FLOW_ID="verify_k8s_pod_resources"

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

pod_resources_json() {
  local execution_id="$1"
  local selector="app.kubernetes.io/name=kestra-pod-resource-verify,kestra-playground.tacogips.io/execution=${execution_id}"
  local pods_json
  local count

  for _ in {1..30}; do
    pods_json="$(kubectl -n "${NAMESPACE}" get pods -l "${selector}" -o json)"
    count="$(jq -r '.items | length' <<<"${pods_json}")"
    if [[ "${count}" == "2" ]]; then
      printf '%s\n' "${pods_json}"
      return 0
    fi

    sleep 2
  done

  echo "Expected two resource verification pods for execution ${execution_id}." >&2
  kubectl -n "${NAMESPACE}" get pods -l "${selector}" -o wide >&2 || true
  return 1
}

assert_pod_resources() {
  local pods_json="$1"
  local resource_class="$2"
  local expected_cpu_request="$3"
  local expected_memory_request="$4"
  local expected_cpu_limit="$5"
  local expected_memory_limit="$6"
  local actual

  actual="$(
    jq -r --arg resource_class "${resource_class}" '
      .items[]
      | select(.metadata.labels["kestra-playground.tacogips.io/resource-class"] == $resource_class)
      | .spec.containers[0].resources
      | [
          .requests.cpu,
          .requests.memory,
          .limits.cpu,
          .limits.memory
        ]
      | @tsv
    ' <<<"${pods_json}"
  )"

  if [[ "${actual}" != "${expected_cpu_request}"$'\t'"${expected_memory_request}"$'\t'"${expected_cpu_limit}"$'\t'"${expected_memory_limit}" ]]; then
    echo "Unexpected ${resource_class} pod resources: ${actual:-missing}" >&2
    jq -r '.items[] | {name: .metadata.name, labels: .metadata.labels, resources: .spec.containers[0].resources}' \
      <<<"${pods_json}" >&2
    return 1
  fi
}

cleanup_resource_pods() {
  local execution_id="$1"
  local selector="app.kubernetes.io/name=kestra-pod-resource-verify,kestra-playground.tacogips.io/execution=${execution_id}"

  kubectl -n "${NAMESPACE}" delete pods -l "${selector}" --ignore-not-found
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
scripts/register-flows.sh "${gke_url}" kestra/flows-k8s-pod-resources

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
    -F "kubernetes_namespace=${NAMESPACE}" \
    "${gke_url%/}/api/v1/main/executions/${FLOW_NAMESPACE}/${FLOW_ID}"
)"
execution_id="$(jq -er '.id' <<<"${response}")"
echo "${FLOW_ID}: ${execution_id}"
execution_json="$(wait_for_execution "${gke_url}" "${gke_username}" "${gke_password}" "${execution_id}")"
pods_json="$(pod_resources_json "${execution_id}")"

assert_pod_resources "${pods_json}" small 500m 512Mi 1 1Gi
assert_pod_resources "${pods_json}" large 2 4Gi 4 8Gi

echo "K8s pod resource verification execution ${execution_id} succeeded."
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

cleanup_resource_pods "${execution_id}"
