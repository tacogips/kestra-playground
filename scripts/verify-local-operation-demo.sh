#!/usr/bin/env bash
set -euo pipefail

BUSINESS_DATE="${1:-${BUSINESS_DATE:-2026-06-25}}"
KESTRA_URL="${KESTRA_URL:-http://localhost:8080}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${KESTRA_ENV_FILE:-}" ]]; then
  if [[ -f "${ROOT_DIR}/local/docker/.env" ]]; then
    KESTRA_ENV_FILE="${ROOT_DIR}/local/docker/.env"
  else
    KESTRA_ENV_FILE="${ROOT_DIR}/kestra/config/envs/local.env"
  fi
fi
export KESTRA_ENV_FILE
set -a
# shellcheck source=/dev/null
source "${KESTRA_ENV_FILE}"
set +a

CURL_AUTH=()
if [[ -n "${KESTRA_BASIC_AUTH_USERNAME:-}" && -n "${KESTRA_BASIC_AUTH_PASSWORD:-}" ]]; then
  CURL_AUTH=(-u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}")
fi

wait_for_execution() {
  local execution_id="$1"
  local execution_json
  local state

  for _ in {1..60}; do
    execution_json="$(
      curl "${CURL_AUTH[@]}" --fail --silent --show-error \
        "${KESTRA_URL%/}/api/v1/main/executions/${execution_id}"
    )"
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

    sleep 2
  done

  echo "Execution ${execution_id} did not finish." >&2
  return 1
}

# Unit-style smoke check for the single batch source, independent of Kestra.
BUSINESS_DATE="${BUSINESS_DATE}" \
  BATCH_ID=resource_probe_unit \
  RESOURCE_CLASS=unit \
  OUTPUT_PATH="${TMPDIR:-/tmp}/kestra-resource-probe-unit.json" \
  "${ROOT_DIR}/batches/resource_probe/run.sh" >/tmp/kestra-resource-probe-unit.log

grep -q "batch_id=resource_probe_unit" /tmp/kestra-resource-probe-unit.log
grep -q "resource_class=unit" /tmp/kestra-resource-probe-unit.log
grep -q "\"business_date\":\"${BUSINESS_DATE}\"" "${TMPDIR:-/tmp}/kestra-resource-probe-unit.json"

"${ROOT_DIR}/scripts/register-flows.sh" "${KESTRA_URL}" "${ROOT_DIR}/kestra/flows-operation-demo/local"
response="$(
  NAMESPACE=playground.operation_demo \
    "${ROOT_DIR}/scripts/run-flow.sh" resource_probe_local "${BUSINESS_DATE}" "${KESTRA_URL}"
)"
execution_id="$(jq -er '.id' <<<"${response}")"
echo "resource_probe_local: ${execution_id}"
execution_json="$(wait_for_execution "${execution_id}")"

jq -r '
  "Task run summary:",
  (["taskId", "state", "workerId"] | @tsv),
  ((.taskRunList // [])[] | [(.taskId // ""), (.state.current // ""), (.workerId // .worker.id // "")] | @tsv)
' <<<"${execution_json}"
