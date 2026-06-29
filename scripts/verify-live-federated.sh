#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
BUSINESS_DATE_INPUT="${1:-${BUSINESS_DATE:-}}"
LIVE_DOMAIN_NAME="${LIVE_DOMAIN_NAME:-}"
LIVE_GCE_A_SUBDOMAIN="${LIVE_GCE_A_SUBDOMAIN:-${LIVE_GCE_SINGLE_SUBDOMAIN:-gce-compose}}"
LIVE_GCE_B_SUBDOMAIN="${LIVE_GCE_B_SUBDOMAIN:-${LIVE_GCE_CLUSTER_SUBDOMAIN:-gce-container}}"
LIVE_GKE_SUBDOMAIN="${LIVE_GKE_SUBDOMAIN:-k8s}"
FEDERATED_VERIFY_RERUN="${FEDERATED_VERIFY_RERUN:-true}"

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
require_command ruby

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

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/kestra-federated-live.XXXXXX")"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

wait_for_ui() {
  local url="$1"
  local username="$2"
  local password="$3"

  for _ in {1..120}; do
    if curl --fail --silent --show-error \
      -u "${username}:${password}" \
      "${url%/}/ui/" >/dev/null; then
      return 0
    fi

    sleep 10
  done

  echo "Kestra UI did not become ready: ${url}" >&2
  return 1
}

flow_status_code() {
  local url="$1"
  local username="$2"
  local password="$3"
  local namespace="$4"
  local flow_id="$5"

  curl --silent --show-error \
    -o /dev/null \
    -w "%{http_code}" \
    -u "${username}:${password}" \
    "${url%/}/api/v1/main/flows/${namespace}/${flow_id}"
}

assert_flow_absent() {
  local url="$1"
  local username="$2"
  local password="$3"
  local namespace="$4"
  local flow_id="$5"
  local status

  status="$(flow_status_code "$url" "$username" "$password" "$namespace" "$flow_id")"
  if [[ "$status" != "404" ]]; then
    echo "Expected ${namespace}/${flow_id} to be absent from ${url}, got HTTP ${status}" >&2
    return 1
  fi
}

delete_flow_if_present() {
  local url="$1"
  local username="$2"
  local password="$3"
  local namespace="$4"
  local flow_id="$5"
  local status

  status="$(flow_status_code "$url" "$username" "$password" "$namespace" "$flow_id")"
  case "$status" in
    200)
      curl --fail --silent --show-error \
        -u "${username}:${password}" \
        -X DELETE \
        "${url%/}/api/v1/main/flows/${namespace}/${flow_id}" >/dev/null
      echo "Deleted stale GKE batch flow ${namespace}/${flow_id}"
      ;;
    404)
      ;;
    *)
      echo "Unexpected status while checking ${namespace}/${flow_id} on ${url}: HTTP ${status}" >&2
      return 1
      ;;
  esac
}

remove_gke_batch_flows() {
  local namespace
  local flow_id
  local namespaces=(
    playground.ecommerce
    playground.ecommerce.server_gce_a
    playground.ecommerce.server_gce_b
    playground.ecommerce.server_gce
    playground.ecommerce.server_gke
  )
  local flow_ids=(
    generate_ecommerce_mock_data
    build_ecommerce_customer_segments
    build_ecommerce_daily_report
  )

  for namespace in "${namespaces[@]}"; do
    for flow_id in "${flow_ids[@]}"; do
      delete_flow_if_present "${gke_url}" "${gke_username}" "${gke_password}" "${namespace}" "${flow_id}"
    done
  done
}

assert_gke_batch_flows_absent() {
  local namespace
  local flow_id
  local namespaces=(
    playground.ecommerce
    playground.ecommerce.server_gce_a
    playground.ecommerce.server_gce_b
    playground.ecommerce.server_gce
    playground.ecommerce.server_gke
  )
  local flow_ids=(
    generate_ecommerce_mock_data
    build_ecommerce_customer_segments
    build_ecommerce_daily_report
  )

  for namespace in "${namespaces[@]}"; do
    for flow_id in "${flow_ids[@]}"; do
      assert_flow_absent "${gke_url}" "${gke_username}" "${gke_password}" "${namespace}" "${flow_id}"
    done
  done
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
        echo "Federated controller execution ${execution_id} ended with state ${state}." >&2
        jq -r '.state.histories // []' <<<"${execution_json}" >&2
        return 1
        ;;
    esac

    sleep 10
  done

  echo "Federated controller execution ${execution_id} did not finish. Last state: ${state:-unknown}" >&2
  return 1
}

assert_controller_only_task_ids() {
  local execution_json="$1"
  local batch_task_ids=(
    generate_ecommerce_mock_data
    build_ecommerce_customer_segments
    build_ecommerce_daily_report
  )
  local task_id

  for task_id in "${batch_task_ids[@]}"; do
    if jq -e --arg task_id "$task_id" '.taskRunList // [] | any(.taskId == $task_id)' <<<"${execution_json}" >/dev/null; then
      echo "Controller execution unexpectedly contains batch task ID: ${task_id}" >&2
      return 1
    fi
  done
}

print_execution_summary() {
  local label="$1"
  local execution_json="$2"
  local execution_id
  execution_id="$(jq -r '.id' <<<"${execution_json}")"

  echo "Federated controller execution ${label} ${execution_id} succeeded."
  jq -r '
    "Task run summary:",
    (["taskId", "state", "workerId"] | @tsv),
    ((.taskRunList // [])[]
      | [
          (.taskId // ""),
          (.state.current // ""),
          (.workerId // .worker.id // .attempts[-1].workerId // "")
        ]
      | @tsv),
    "Execution outputs:",
    ((.outputs // [])[]
      | [
          (.taskId // ""),
          ((.value // .output // .) | tostring)
        ]
      | @tsv)
  ' <<<"${execution_json}"
}

run_controller_once() {
  local label="$1"
  local response
  local execution_id
  local execution_json

  response="$(
    NAMESPACE=playground.ecommerce.controller \
      scripts/run-flow.sh run_federated_ecommerce_batch "${BUSINESS_DATE}" "${gke_url}"
  )"
  execution_id="$(jq -er '.id' <<<"${response}")"
  echo "run_federated_ecommerce_batch (${label}): ${execution_id}"
  execution_json="$(wait_for_execution "${gke_url}" "${gke_username}" "${gke_password}" "${execution_id}")"
  assert_controller_only_task_ids "${execution_json}"
  print_execution_summary "${label}" "${execution_json}"
}

gce_a_url="https://${LIVE_GCE_A_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
gce_b_url="https://${LIVE_GCE_B_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
gke_url="https://${LIVE_GKE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"

gce_a_username="$(secret_value kestra-dev-kestra-basic-auth-username)"
gce_a_password="$(secret_value kestra-dev-kestra-basic-auth-password)"
gce_b_username="$(secret_value kestra-cluster-dev-kestra-basic-auth-username)"
gce_b_password="$(secret_value kestra-cluster-dev-kestra-basic-auth-password)"
gke_username="$(secret_value kestra-dev-gke-kestra-basic-auth-username)"
gke_password="$(secret_value kestra-dev-gke-kestra-basic-auth-password)"

echo "=== Federated child: GCE A (${gce_a_url}) ==="
export KESTRA_BASIC_AUTH_USERNAME="${gce_a_username}"
export KESTRA_BASIC_AUTH_PASSWORD="${gce_a_password}"
wait_for_ui "${gce_a_url}" "${gce_a_username}" "${gce_a_password}"
gce_a_flow_dir="$("${SCRIPT_DIR}/render-federated-child-flows.sh" gce_a kestra/flows "${tmp_dir}/server_gce_a")"
scripts/register-flows.sh "${gce_a_url}" "${gce_a_flow_dir}"

echo "=== Federated child: GCE B (${gce_b_url}) ==="
export KESTRA_BASIC_AUTH_USERNAME="${gce_b_username}"
export KESTRA_BASIC_AUTH_PASSWORD="${gce_b_password}"
wait_for_ui "${gce_b_url}" "${gce_b_username}" "${gce_b_password}"
gce_b_flow_dir="$("${SCRIPT_DIR}/render-federated-child-flows.sh" gce_b kestra/flows "${tmp_dir}/server_gce_b")"
scripts/register-flows.sh "${gce_b_url}" "${gce_b_flow_dir}"

echo "=== Federated controller only: GKE (${gke_url}) ==="
export KESTRA_BASIC_AUTH_USERNAME="${gke_username}"
export KESTRA_BASIC_AUTH_PASSWORD="${gke_password}"
wait_for_ui "${gke_url}" "${gke_username}" "${gke_password}"
remove_gke_batch_flows
scripts/register-flows.sh "${gke_url}" kestra/flows-federated
assert_gke_batch_flows_absent
echo "Verified no batch child namespaces are registered on GKE controller."

run_controller_once "initial"
if [[ "${FEDERATED_VERIFY_RERUN}" == "true" ]]; then
  run_controller_once "rerun"
fi
