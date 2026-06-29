#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUSINESS_DATE_INPUT="${1:-${BUSINESS_DATE:-}}"
KESTRA_ENV_FILE="${KESTRA_ENV_FILE:-}"
KESTRA_BASIC_AUTH_USERNAME_OVERRIDE="${KESTRA_BASIC_AUTH_USERNAME:-}"
KESTRA_BASIC_AUTH_PASSWORD_OVERRIDE="${KESTRA_BASIC_AUTH_PASSWORD:-}"

if [[ -z "${KESTRA_ENV_FILE}" ]]; then
  if [[ -f local/docker/.env ]]; then
    KESTRA_ENV_FILE=local/docker/.env
  else
    KESTRA_ENV_FILE=kestra/config/envs/local.env
  fi
fi

set -a
# shellcheck source=/dev/null
source "${KESTRA_ENV_FILE}"
set +a

if [[ -n "${KESTRA_BASIC_AUTH_USERNAME_OVERRIDE}" ]]; then
  KESTRA_BASIC_AUTH_USERNAME="${KESTRA_BASIC_AUTH_USERNAME_OVERRIDE}"
  export KESTRA_BASIC_AUTH_USERNAME
fi
if [[ -n "${KESTRA_BASIC_AUTH_PASSWORD_OVERRIDE}" ]]; then
  KESTRA_BASIC_AUTH_PASSWORD="${KESTRA_BASIC_AUTH_PASSWORD_OVERRIDE}"
  export KESTRA_BASIC_AUTH_PASSWORD
fi

# shellcheck source=scripts/lib/business-date.sh
source "${SCRIPT_DIR}/lib/business-date.sh"
BUSINESS_DATE="$(resolve_business_date "${BUSINESS_DATE_INPUT}")"
KESTRA_URL="${KESTRA_URL:-http://localhost:8080}"
ENV_FEDERATED_GCE_A_URL="${ENV_FEDERATED_GCE_A_URL:-${KESTRA_URL}}"
ENV_FEDERATED_GCE_A_USERNAME="${ENV_FEDERATED_GCE_A_USERNAME:-${KESTRA_BASIC_AUTH_USERNAME:-}}"
ENV_FEDERATED_GCE_A_PASSWORD="${ENV_FEDERATED_GCE_A_PASSWORD:-${KESTRA_BASIC_AUTH_PASSWORD:-}}"
ENV_FEDERATED_GCE_B_URL="${ENV_FEDERATED_GCE_B_URL:-${KESTRA_URL}}"
ENV_FEDERATED_GCE_B_USERNAME="${ENV_FEDERATED_GCE_B_USERNAME:-${KESTRA_BASIC_AUTH_USERNAME:-}}"
ENV_FEDERATED_GCE_B_PASSWORD="${ENV_FEDERATED_GCE_B_PASSWORD:-${KESTRA_BASIC_AUTH_PASSWORD:-}}"
export ENV_FEDERATED_GCE_A_URL
export ENV_FEDERATED_GCE_A_USERNAME
export ENV_FEDERATED_GCE_A_PASSWORD
export ENV_FEDERATED_GCE_B_URL
export ENV_FEDERATED_GCE_B_USERNAME
export ENV_FEDERATED_GCE_B_PASSWORD

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command curl
require_command jq
require_command ruby

CURL_AUTH=()
if [[ -n "${KESTRA_BASIC_AUTH_USERNAME:-}" && -n "${KESTRA_BASIC_AUTH_PASSWORD:-}" ]]; then
  CURL_AUTH=(-u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}")
fi

wait_for_execution() {
  local execution_id="$1"
  local status_url="${KESTRA_URL%/}/api/v1/main/executions/${execution_id}"
  local execution_json
  local state=""

  for _ in {1..120}; do
    execution_json="$(
      curl "${CURL_AUTH[@]}" --fail --silent --show-error "${status_url}"
    )"
    state="$(jq -r '.state.current // empty' <<<"${execution_json}")"

    case "${state}" in
      SUCCESS)
        echo "${execution_json}"
        return 0
        ;;
      FAILED | KILLED | WARNING)
        echo "Federated local controller execution ${execution_id} ended with state ${state}." >&2
        jq -r '.state.histories // []' <<<"${execution_json}" >&2
        return 1
        ;;
    esac

    sleep 5
  done

  echo "Federated local controller execution ${execution_id} did not finish. Last state: ${state:-unknown}" >&2
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

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/kestra-federated-local.XXXXXX")"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

echo "=== Local federated child namespaces (${KESTRA_URL}) ==="
gce_a_flow_dir="$("${SCRIPT_DIR}/render-federated-child-flows.sh" gce_a kestra/flows "${tmp_dir}/server_gce_a")"
gce_b_flow_dir="$("${SCRIPT_DIR}/render-federated-child-flows.sh" gce_b kestra/flows "${tmp_dir}/server_gce_b")"

scripts/register-flows.sh "${KESTRA_URL}" "${gce_a_flow_dir}"
scripts/register-flows.sh "${KESTRA_URL}" "${gce_b_flow_dir}"
scripts/register-flows.sh "${KESTRA_URL}" kestra/flows-federated

response="$(
  NAMESPACE=playground.ecommerce.controller \
    scripts/run-flow.sh run_federated_ecommerce_batch "${BUSINESS_DATE}" "${KESTRA_URL}"
)"
execution_id="$(jq -er '.id' <<<"${response}")"
echo "run_federated_ecommerce_batch: ${execution_id}"
execution_json="$(wait_for_execution "${execution_id}")"
assert_controller_only_task_ids "${execution_json}"
echo "Federated local controller execution ${execution_id} succeeded."
printf '%s\n' "${execution_json}" | jq -r '
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
'
