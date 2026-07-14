#!/usr/bin/env bash
set -euo pipefail

BUSINESS_DATE="${1:-${BUSINESS_DATE:-2026-06-25}}"
KESTRA_URL="${KESTRA_URL:-http://localhost:8080}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="playground.remote_batch"
COMPOSE_FILE="${ROOT_DIR}/local/docker/docker-compose.yml"
COMPOSE_ENV_FILE="${ROOT_DIR}/local/docker/.env"

if [[ ! -f "${COMPOSE_ENV_FILE}" ]]; then
  COMPOSE_ENV_FILE="${ROOT_DIR}/local/docker/.env.example"
fi

if [[ -z "${KESTRA_ENV_FILE:-}" ]]; then
  if [[ -f "${ROOT_DIR}/batch-groups/ec/config/envs/local.env" ]]; then
    KESTRA_ENV_FILE="${ROOT_DIR}/batch-groups/ec/config/envs/local.env"
  else
    KESTRA_ENV_FILE="${ROOT_DIR}/batch-groups/ec/config/envs/local.env.example"
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

submit_flow() {
  local flow_id="$1"
  shift

  local form_args=(-F "business_date=${BUSINESS_DATE}")
  local item
  for item in "$@"; do
    form_args+=(-F "${item}")
  done

  curl "${CURL_AUTH[@]}" --fail --silent --show-error \
    -X POST \
    "${form_args[@]}" \
    "${KESTRA_URL%/}/api/v1/main/executions/${NAMESPACE}/${flow_id}"
}

wait_for_execution() {
  local execution_id="$1"
  local expected_state="$2"
  local destination="$3"
  local execution_json
  local state

  for _ in {1..90}; do
    execution_json="$(
      curl "${CURL_AUTH[@]}" --fail --silent --show-error \
        "${KESTRA_URL%/}/api/v1/main/executions/${execution_id}"
    )"
    state="$(jq -r '.state.current // empty' <<<"${execution_json}")"

    case "${state}" in
      SUCCESS | FAILED | KILLED | CANCELLED | WARNING)
        printf '%s\n' "${execution_json}" >"${destination}"
        if [[ "${state}" != "${expected_state}" ]]; then
          echo "Execution ${execution_id} ended with ${state}; expected ${expected_state}." >&2
          jq -r '.taskRunList // []' <<<"${execution_json}" >&2
          return 1
        fi
        return 0
        ;;
    esac

    sleep 2
  done

  echo "Execution ${execution_id} did not finish." >&2
  return 1
}

print_execution_evidence() {
  local label="$1"
  local execution_file="$2"

  echo "${label}:"
  jq -r '
    (["taskId", "state"] | @tsv),
    ((.taskRunList // [])[] | [(.taskId // ""), (.state.current // "")] | @tsv),
    "outputs=" + ((.outputs // []) | tostring)
  ' "${execution_file}"
}

fetch_child_execution() {
  local parent_file="$1"
  local child_file="$2"
  local child_execution_id

  child_execution_id="$(
    jq -er '.taskRunList[] | select(.taskId == "run_remote_batch") | .outputs.executionId' \
      "${parent_file}"
  )"
  curl "${CURL_AUTH[@]}" --fail --silent --show-error \
    "${KESTRA_URL%/}/api/v1/main/executions/${child_execution_id}" >"${child_file}"
  printf '%s' "${child_execution_id}"
}

fetch_execution_logs() {
  local execution_id="$1"
  local destination="$2"

  curl "${CURL_AUTH[@]}" --fail --silent --show-error \
    "${KESTRA_URL%/}/api/v1/main/logs/${execution_id}" \
    | jq '(if type == "array" then . else (.results // []) end)' >"${destination}"
}

assert_no_remote_workspaces() {
  docker compose \
    --env-file "${COMPOSE_ENV_FILE}" \
    -f "${COMPOSE_FILE}" \
    exec -T remote-worker sh -eu -c '
      workspace_root=/home/batch/kestra-runs
      if [ -d "${workspace_root}" ] \
        && find "${workspace_root}" -mindepth 1 -print -quit | grep -q .; then
        echo "Residual remote batch workspace found:" >&2
        find "${workspace_root}" -mindepth 1 -maxdepth 2 -print >&2
        exit 1
      fi
    '
}

assert_child_success() {
  local flow_id="$1"
  local child_file="$2"
  local logs_file="$3"

  jq -e '
    .state.current == "SUCCESS"
    and ([.taskRunList[].state.current] | all(. == "SUCCESS"))
    and (.outputs.artifact | startswith("kestra:///"))
    and (.outputs.artifact_checksum | test("^[0-9a-f]{64}$"))
  ' "${child_file}" >/dev/null
  jq -e '
    any(.[]; .taskId == "stage_source" and (.message | contains("uploaded to '"'"'sftp://")))
    and any(.[]; .taskId == "execute_batch" and (.message | contains("progress phase=complete")))
    and any(.[]; .taskId == "cleanup_workspace" and (.message | contains("workspace_cleaned verified=true")))
  ' "${logs_file}" >/dev/null

  case "${flow_id}" in
    export_database_to_csv)
      jq -e '
        any(.taskRunList[]; .taskId == "execute_batch" and .outputs.vars.row_count == 3)
      ' "${child_file}" >/dev/null
      ;;
    parse_application_logs)
      jq -e '
        any(
          .taskRunList[];
          .taskId == "execute_batch"
          and .outputs.vars.total_lines == 3
          and .outputs.vars.error_lines == 1
        )
      ' "${child_file}" >/dev/null
      ;;
  esac
}

assert_child_failure() {
  local child_file="$1"
  local logs_file="$2"

  jq -e '
    .state.current == "FAILED"
    and any(.taskRunList[]; .taskId == "execute_batch" and .state.current == "FAILED")
    and any(.taskRunList[]; .taskId == "cleanup_failed_workspace" and .state.current == "SUCCESS")
  ' "${child_file}" >/dev/null
  jq -e '
    any(.[]; .taskId == "execute_batch" and (.message | contains("batch_error type=FileNotFoundError")))
    and any(.[]; .taskId == "cleanup_failed_workspace" and (.message | contains("workspace_cleaned verified=true")))
    and all(.[]; (.message | contains("Failed to render output values")) | not)
  ' "${logs_file}" >/dev/null
}

run_and_assert() {
  local flow_id="$1"
  local expected_state="$2"
  shift 2

  local response
  local execution_id
  local execution_file
  local child_execution_id
  local child_file
  local logs_file

  response="$(submit_flow "${flow_id}" "$@")"
  execution_id="$(jq -er '.id' <<<"${response}")"
  execution_file="$(mktemp)"
  child_file="$(mktemp)"
  logs_file="$(mktemp)"
  wait_for_execution "${execution_id}" "${expected_state}" "${execution_file}"
  print_execution_evidence "${flow_id} ${execution_id}" "${execution_file}"
  child_execution_id="$(fetch_child_execution "${execution_file}" "${child_file}")"
  fetch_execution_logs "${child_execution_id}" "${logs_file}"

  if [[ "${expected_state}" == "SUCCESS" ]]; then
    assert_child_success "${flow_id}" "${child_file}" "${logs_file}"
  else
    assert_child_failure "${child_file}" "${logs_file}"
  fi

  echo "remote_batch_runner ${child_execution_id}:"
  jq -r '(.taskRunList // [])[] | [.taskId, .state.current] | @tsv' "${child_file}"
  jq -r '.[] | select(.message | contains("progress ") or contains("batch_error ")) | [.taskId, .level, .message] | @tsv' \
    "${logs_file}"
  assert_no_remote_workspaces
  rm -f "${execution_file}" "${child_file}" "${logs_file}"
}

REMOTE_BATCH_ADAPTER=ssh \
  "${ROOT_DIR}/scripts/register-remote-batch-demo.sh" "${KESTRA_URL}"

run_and_assert export_database_to_csv SUCCESS
run_and_assert parse_application_logs SUCCESS
run_and_assert parse_application_logs FAILED "log_path=/opt/batch-inputs/missing.jsonl"

echo "Verified remote source staging, execution, artifact collection, and failure propagation."
