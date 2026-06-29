#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
ZONE="${ZONE:-asia-northeast1-a}"
NAMESPACE="${NAMESPACE:-kestra-dev}"
BUSINESS_DATE_INPUT="${1:-${BUSINESS_DATE:-}}"
LIVE_DOMAIN_NAME="${LIVE_DOMAIN_NAME:-}"
LIVE_GKE_SUBDOMAIN="${LIVE_GKE_SUBDOMAIN:-k8s}"
FLOW_NAMESPACE="playground.worker_routing"
FLOW_ID="verify_gcp_worker_routing"

# shellcheck source=scripts/lib/business-date.sh
source "${SCRIPT_DIR}/lib/business-date.sh"

BUSINESS_DATE="$(resolve_business_date "${BUSINESS_DATE_INPUT}")"

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
require_command tofu

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

dump_gke_diagnostics() {
  echo "=== GKE routed diagnostics ===" >&2
  kubectl -n "${NAMESPACE}" get pods -o wide >&2 || true
  kubectl -n "${NAMESPACE}" get deployment kestra-webserver -o wide >&2 || true
  kubectl -n "${NAMESPACE}" get service kestra-webserver -o wide >&2 || true
  kubectl -n "${NAMESPACE}" get endpointslice -l kubernetes.io/service-name=kestra-webserver -o wide >&2 || true
  kubectl -n "${NAMESPACE}" get ingress kestra-webserver -o wide >&2 || true
  kubectl -n "${NAMESPACE}" get backendconfig kestra-webserver -o yaml >&2 || true
  kubectl -n "${NAMESPACE}" describe ingress kestra-webserver >&2 || true
  kubectl -n "${NAMESPACE}" describe pods \
    -l app.kubernetes.io/name=kestra,app.kubernetes.io/component=webserver >&2 || true
  kubectl -n "${NAMESPACE}" logs deployment/kestra-webserver -c kestra --tail=200 >&2 || true
  # shellcheck disable=SC2016
  kubectl -n "${NAMESPACE}" run kestra-webserver-probe \
    --rm \
    --quiet \
    --attach \
    --restart=Never \
    --image=curlimages/curl:8.11.1 \
    --command -- sh -ec '
      for target in \
        http://kestra-webserver/ \
        http://kestra-webserver/ui/ \
        http://kestra-webserver:8081/health \
        http://kestra-webserver:8081/health/readiness \
        http://kestra-webserver:8081/health/liveness; do
        echo ">>> ${target}" >&2
        curl -sS -o /dev/null -w "%{http_code}\n" "${target}" >&2 || true
      done
    ' >&2 || true
}

wait_for_ui() {
  local url="$1"
  local username="$2"
  local password="$3"

  for _ in {1..120}; do
    if curl --fail --silent --show-error \
      -u "${username}:${password}" \
      "${url%/}/" >/dev/null; then
      return 0
    fi

    sleep 10
  done

  echo "Kestra UI did not become ready: ${url}" >&2
  dump_gke_diagnostics
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
        echo "${execution_json}"
        return 0
        ;;
      FAILED | KILLED | WARNING)
        echo "Routed worker verification execution ${execution_id} ended with state ${state}." >&2
        jq -r '.state.histories // []' <<<"${execution_json}" >&2
        return 1
        ;;
    esac

    sleep 10
  done

  echo "Routed worker verification execution ${execution_id} did not finish. Last state: ${state:-unknown}" >&2
  return 1
}

assert_no_gke_worker() {
  if kubectl -n "${NAMESPACE}" get deployment kestra-worker >/dev/null 2>&1; then
    echo "Unexpected GKE worker deployment exists: kestra-worker" >&2
    return 1
  fi

  local worker_pod_count
  worker_pod_count="$(
    kubectl -n "${NAMESPACE}" get pods \
      -l app.kubernetes.io/name=kestra,app.kubernetes.io/component=worker \
      -o json \
      | jq '.items | length'
  )"

  if [[ "${worker_pod_count}" != "0" ]]; then
    echo "Unexpected GKE worker pods exist: ${worker_pod_count}" >&2
    return 1
  fi
}

assert_controller_grpc_service() {
  local grpc_ip
  grpc_ip="$(
    kubectl -n "${NAMESPACE}" get service kestra-controller-grpc \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
  )"

  if [[ -z "${grpc_ip}" ]]; then
    echo "kestra-controller-grpc does not have an assigned internal LoadBalancer IP." >&2
    return 1
  fi
}

assert_gce_workers_running() {
  local -a worker_instances=()
  mapfile -t worker_instances < <(
    tofu -chdir=infra/terraform/gke-dev output -json gce_worker_instances \
      | jq -r '.[]'
  )

  if [[ "${#worker_instances[@]}" -lt 3 ]]; then
    echo "Expected at least 3 GCE worker instances, got ${#worker_instances[@]}" >&2
    return 1
  fi

  local instance
  local status
  for instance in "${worker_instances[@]}"; do
    status="$(
      gcloud compute instances describe "${instance}" \
        --zone "${ZONE}" \
        --project "${PROJECT_ID}" \
        --format='value(status)'
    )"
    if [[ "${status}" != "RUNNING" ]]; then
      echo "Expected GCE worker ${instance} to be RUNNING, got ${status}" >&2
      return 1
    fi
  done
}

assert_task_success() {
  local execution_json="$1"
  local task_id="$2"
  local state

  state="$(
    jq -er --arg task_id "${task_id}" '
      [.taskRunList // [] | .[] | select(.taskId == $task_id) | .state.current][-1]
    ' <<<"${execution_json}"
  )"

  if [[ "${state}" != "SUCCESS" ]]; then
    echo "Expected task ${task_id} to be SUCCESS, got ${state}" >&2
    return 1
  fi
}

task_worker_id() {
  local execution_json="$1"
  local task_id="$2"

  jq -er --arg task_id "${task_id}" '
    [
      .taskRunList // []
      | .[]
      | select(.taskId == $task_id)
      | (.workerId // .worker.id // .attempts[-1].workerId // "")
    ][-1]
  ' <<<"${execution_json}"
}

print_execution_summary() {
  local execution_json="$1"
  local execution_id
  execution_id="$(jq -r '.id' <<<"${execution_json}")"

  echo "Routed worker verification execution ${execution_id} succeeded."
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
}

gke_url="https://${LIVE_GKE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
gke_username="$(secret_value kestra-dev-gke-kestra-basic-auth-username)"
gke_password="$(secret_value kestra-dev-gke-kestra-basic-auth-password)"

gcloud container clusters get-credentials kestra-dev \
  --region "${REGION}" \
  --project "${PROJECT_ID}"

echo "=== Routed shared-backend controller: GKE (${gke_url}) ==="
export KESTRA_BASIC_AUTH_USERNAME="${gke_username}"
export KESTRA_BASIC_AUTH_PASSWORD="${gke_password}"
wait_for_ui "${gke_url}" "${gke_username}" "${gke_password}"
assert_no_gke_worker
assert_controller_grpc_service
assert_gce_workers_running

scripts/register-flows.sh "${gke_url}" kestra/flows-worker-routing

response="$(
  NAMESPACE="${FLOW_NAMESPACE}" \
    scripts/run-flow.sh "${FLOW_ID}" "${BUSINESS_DATE}" "${gke_url}"
)"
execution_id="$(jq -er '.id' <<<"${response}")"
echo "${FLOW_ID}: ${execution_id}"
execution_json="$(wait_for_execution "${gke_url}" "${gke_username}" "${gke_password}" "${execution_id}")"

assert_task_success "${execution_json}" run_on_gce_a
assert_task_success "${execution_json}" run_on_gce_b

worker_a="$(task_worker_id "${execution_json}" run_on_gce_a)"
worker_b="$(task_worker_id "${execution_json}" run_on_gce_b)"

if [[ -z "${worker_a}" || -z "${worker_b}" ]]; then
  echo "Expected both routed tasks to report worker IDs." >&2
  exit 1
fi

if [[ "${worker_a}" == "${worker_b}" ]]; then
  echo "Expected routed tasks to run on different workers, got ${worker_a} for both." >&2
  exit 1
fi

print_execution_summary "${execution_json}"
