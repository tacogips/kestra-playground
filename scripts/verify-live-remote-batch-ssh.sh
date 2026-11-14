#!/usr/bin/env bash
set -euo pipefail

BUSINESS_DATE="${1:-${BUSINESS_DATE:-2026-06-25}}"
PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
ZONE="${ZONE:-asia-northeast1-a}"
INSTANCE_A="${REMOTE_BATCH_INSTANCE_A:-kestra-remote-batch-a}"
INSTANCE_B="${REMOTE_BATCH_INSTANCE_B:-kestra-remote-batch-b}"
KESTRA_URL="${KESTRA_URL:-http://localhost:8080}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="playground.remote_batch"
FLOW_ID="parse_application_logs_multi_target"
FAILURE_MARKER="/tmp/kestra-fail-execute-once"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "PROJECT_ID or GCP_PROJECT_ID is required." >&2
  exit 1
fi

if [[ -z "${KESTRA_ENV_FILE:-}" ]]; then
  KESTRA_ENV_FILE="${ROOT_DIR}/batch-groups/ec/config/envs/local.env"
fi
if [[ ! -f "${KESTRA_ENV_FILE}" ]]; then
  KESTRA_ENV_FILE="${ROOT_DIR}/batch-groups/ec/config/envs/local.env.example"
fi
export KESTRA_ENV_FILE
set -a
# shellcheck source=/dev/null
source "${KESTRA_ENV_FILE}"
set +a

CURL_AUTH=(-u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}")
GCLOUD=(gcloud --project="${PROJECT_ID}" --quiet)
TARGET_A_IP="$(
  "${GCLOUD[@]}" compute instances describe "${INSTANCE_A}" \
    --zone="${ZONE}" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)'
)"
TARGET_B_IP="$(
  "${GCLOUD[@]}" compute instances describe "${INSTANCE_B}" \
    --zone="${ZONE}" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)'
)"
TARGETS="$(
  jq -cn \
    --arg target_a_ip "${TARGET_A_IP}" \
    --arg target_b_ip "${TARGET_B_IP}" '
      [
        {
          id: "gcp-worker-a",
          host: $target_a_ip,
          port: 22,
          username: "batch",
          password_secret: "REMOTE_BATCH_PASSWORD",
          execute_failure_marker: ""
        },
        {
          id: "gcp-worker-b",
          host: $target_b_ip,
          port: 22,
          username: "batch",
          password_secret: "REMOTE_BATCH_PASSWORD",
          execute_failure_marker: "/tmp/kestra-fail-execute-once"
        }
      ]
    '
)"

restore_target_b() {
  "${GCLOUD[@]}" compute ssh "${INSTANCE_B}" \
    --zone="${ZONE}" \
    --command="sudo rm -f -- ${FAILURE_MARKER}" >/dev/null 2>&1 || true
}
trap restore_target_b EXIT

execution_json() {
  local execution_id="$1"

  curl "${CURL_AUTH[@]}" --fail --silent --show-error \
    "${KESTRA_URL%/}/api/v1/main/executions/${execution_id}"
}

submit_multi_target() {
  curl "${CURL_AUTH[@]}" --fail --silent --show-error \
    -X POST \
    -F "business_date=${BUSINESS_DATE}" \
    -F "targets=${TARGETS}" \
    "${KESTRA_URL%/}/api/v1/main/executions/${NAMESPACE}/${FLOW_ID}" \
    | jq -er '.id'
}

wait_for_terminal() {
  local execution_id="$1"
  local destination="$2"
  local body
  local state

  for _ in {1..150}; do
    body="$(execution_json "${execution_id}")"
    state="$(jq -r '.state.current // empty' <<<"${body}")"
    case "${state}" in
      SUCCESS | FAILED | KILLED | CANCELLED | WARNING)
        printf '%s\n' "${body}" >"${destination}"
        return 0
        ;;
    esac
    sleep 2
  done

  echo "Execution ${execution_id} did not finish." >&2
  return 1
}

correlated_execution_id() {
  local correlation_id="$1"
  local flow_id="$2"
  local target_id="${3:-}"

  curl "${CURL_AUTH[@]}" --fail --silent --show-error --get \
    --data-urlencode "size=100" \
    --data-urlencode "filters[labels][EQUALS][system.correlationId]=${correlation_id}" \
    --data-urlencode "filters[flowId][EQUALS]=${flow_id}" \
    "${KESTRA_URL%/}/api/v1/main/executions/search" \
    | jq -er --arg target_id "${target_id}" '
        [.results[] | select($target_id == "" or .inputs.target_id == $target_id)]
        | if length == 1 then .[0].id else error("expected exactly one correlated execution") end
      '
}

assert_child_step_attempts() {
  local execution_id="$1"
  local expected_target_id="$2"
  local expected_execute_attempts="$3"
  local execution_file

  execution_file="$(mktemp)"
  execution_json "${execution_id}" >"${execution_file}"
  jq -e \
    --arg expected_target_id "${expected_target_id}" \
    --argjson expected_execute_attempts "${expected_execute_attempts}" '
      .state.current == "SUCCESS"
      and .metadata.attemptNumber == 1
      and .inputs.target_id == $expected_target_id
      and .outputs.target_id == $expected_target_id
      and (.outputs.artifact_checksum | test("^[0-9a-f]{64}$"))
      and any(.taskRunList[]; .taskId == "prepare_workspace" and (.attempts | length) == 1)
      and any(.taskRunList[]; .taskId == "stage_source" and (.attempts | length) == 1)
      and any(.taskRunList[]; .taskId == "validate_input" and (.attempts | length) == 1)
      and ([.taskRunList[] | select(.taskId == "execute_batch" and .state.current == "SUCCESS")] | length) == 1
      and ([.taskRunList[] | select(.taskId == "execute_batch") | .attempts[]] | length) >= $expected_execute_attempts
      and (
        $expected_execute_attempts == 1
        or ([.taskRunList[] | select(.taskId == "execute_batch") | .attempts[] | select(.state.current == "FAILED")] | length) >= 1
      )
      and any(.taskRunList[]; .taskId == "validate_output" and (.attempts | length) == 1)
      and any(.taskRunList[]; .taskId == "collect_artifact" and (.attempts | length) == 1)
    ' "${execution_file}" >/dev/null
  rm -f "${execution_file}"
}

print_target_evidence() {
  local label="$1"
  shift

  echo "${label}:"
  echo $'target\tstate\tchild_attempt\tvalidate_input_attempts\texecute_attempts\tvalidate_output_attempts\texecution_id'
  local execution_id
  for execution_id in "$@"; do
    execution_json "${execution_id}" \
      | jq -r '[.inputs.target_id, .state.current, .metadata.attemptNumber,
        ([.taskRunList[] | select(.taskId == "validate_input") | .attempts[]] | length),
        ([.taskRunList[] | select(.taskId == "execute_batch") | .attempts[]] | length),
        ([.taskRunList[] | select(.taskId == "validate_output") | .attempts[]] | length), .id]
        | @tsv'
  done
}

inject_target_b_execute_failure() {
  "${GCLOUD[@]}" compute ssh "${INSTANCE_B}" \
    --zone="${ZONE}" \
    --command="sudo -u batch touch ${FAILURE_MARKER}"
}

assert_no_remote_workspaces() {
  local instance_name

  for instance_name in "${INSTANCE_A}" "${INSTANCE_B}"; do
    # The workspace variables must expand on the target VM, not in this shell.
    # shellcheck disable=SC2016
    "${GCLOUD[@]}" compute ssh "${instance_name}" \
      --zone="${ZONE}" \
      --command='sudo sh -eu -c '\''
        workspace_root=/home/batch/kestra-runs
        if [ -d "${workspace_root}" ] \
          && find "${workspace_root}" -mindepth 1 -print -quit | grep -q .; then
          find "${workspace_root}" -mindepth 1 -maxdepth 2 -print >&2
          exit 1
        fi
      '\''' >/dev/null
  done
}

assert_no_target_kestra_runtime() {
  local instance_name

  for instance_name in "${INSTANCE_A}" "${INSTANCE_B}"; do
    "${GCLOUD[@]}" compute ssh "${instance_name}" \
      --zone="${ZONE}" \
      --command='sudo sh -eu -c '\''
        if command -v kestra >/dev/null 2>&1; then
          echo "Unexpected Kestra binary on remote target." >&2
          exit 1
        fi
        if ps -eo args | grep -Eq "io[.]kestra|kestra server (worker|standalone|executor|scheduler|webserver|indexer)"; then
          echo "Unexpected Kestra process on remote target." >&2
          exit 1
        fi
        if command -v docker >/dev/null 2>&1 \
          && docker ps --format "{{.Image}} {{.Command}}" | grep -qi kestra; then
          echo "Unexpected Kestra container on remote target." >&2
          exit 1
        fi
      '\''' >/dev/null
  done
}

REMOTE_BATCH_ADAPTER=ssh \
  "${ROOT_DIR}/scripts/register-remote-batch-demo.sh" "${KESTRA_URL}"
assert_no_target_kestra_runtime

baseline_parent_id="$(submit_multi_target)"
baseline_parent_file="$(mktemp)"
wait_for_terminal "${baseline_parent_id}" "${baseline_parent_file}"
jq -e '.state.current == "SUCCESS"' "${baseline_parent_file}" >/dev/null
baseline_multi_id="$(correlated_execution_id "${baseline_parent_id}" multi_target_remote_batch_runner)"
baseline_worker_a_id="$(correlated_execution_id "${baseline_parent_id}" remote_batch_runner gcp-worker-a)"
baseline_worker_b_id="$(correlated_execution_id "${baseline_parent_id}" remote_batch_runner gcp-worker-b)"
assert_child_step_attempts "${baseline_worker_a_id}" gcp-worker-a 1
assert_child_step_attempts "${baseline_worker_b_id}" gcp-worker-b 1
print_target_evidence \
  "GCP baseline execution ${baseline_multi_id}" \
  "${baseline_worker_a_id}" \
  "${baseline_worker_b_id}"
assert_no_remote_workspaces
assert_no_target_kestra_runtime

inject_target_b_execute_failure
retry_parent_id="$(submit_multi_target)"

retry_parent_file="$(mktemp)"
wait_for_terminal "${retry_parent_id}" "${retry_parent_file}"
jq -e '.state.current == "SUCCESS"' "${retry_parent_file}" >/dev/null
retry_multi_id="$(correlated_execution_id "${retry_parent_id}" multi_target_remote_batch_runner)"
retry_worker_a_id="$(correlated_execution_id "${retry_parent_id}" remote_batch_runner gcp-worker-a)"
retry_worker_b_id="$(correlated_execution_id "${retry_parent_id}" remote_batch_runner gcp-worker-b)"
assert_child_step_attempts "${retry_worker_a_id}" gcp-worker-a 1
assert_child_step_attempts "${retry_worker_b_id}" gcp-worker-b 2
print_target_evidence \
  "GCP isolated retry execution ${retry_multi_id}" \
  "${retry_worker_a_id}" \
  "${retry_worker_b_id}"
assert_no_remote_workspaces

rm -f \
  "${baseline_parent_file}" \
  "${retry_parent_file}"

echo "Verified GCP two-target SSH fan-out and an isolated execute-task retry between one-attempt validation tasks."
