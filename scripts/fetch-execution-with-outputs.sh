#!/usr/bin/env bash
set -euo pipefail

EXECUTION_ID="${1:?Usage: fetch-execution-with-outputs.sh <execution-id>}"
if [[ -n "${KESTRA_ENV_FILE:-}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${KESTRA_ENV_FILE}"
  set +a
fi
KESTRA_URL="${KESTRA_URL:-http://localhost:8080}"
CURL_AUTH=()
if [[ -n "${KESTRA_BASIC_AUTH_USERNAME:-}" && -n "${KESTRA_BASIC_AUTH_PASSWORD:-}" ]]; then
  CURL_AUTH=(-u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}")
fi

fetch() {
  curl ${CURL_AUTH[@]+"${CURL_AUTH[@]}"} --fail --silent --show-error \
    "${KESTRA_URL%/}/api/v1/main/$1"
}

execution="$(fetch "executions/${EXECUTION_ID}")"
if jq -e 'has("outputs") or (.state.current | IN("CREATED", "RUNNING", "RESTARTED", "QUEUED", "PAUSED"))' \
  <<<"${execution}" >/dev/null; then
  printf '%s\n' "${execution}"
  exit 0
fi

# Kestra 2 stores outputs separately from the execution API response.
flow_outputs="$(fetch "outputs/executions/${EXECUTION_ID}")"
execution="$(jq --argjson outputs "${flow_outputs}" '.outputs = $outputs' <<<"${execution}")"
task_outputs="$(fetch "outputs/tasks/${EXECUTION_ID}")"
while IFS= read -r task_run_id; do
  outputs="$(fetch "outputs/tasks/${EXECUTION_ID}/${task_run_id}")"
  execution="$(jq --arg id "${task_run_id}" --argjson outputs "${outputs}" \
    '(.taskRunList[] | select(.id == $id)).outputs = $outputs' <<<"${execution}")"
done < <(jq -r '.[].taskRunId' <<<"${task_outputs}")
printf '%s\n' "${execution}"
