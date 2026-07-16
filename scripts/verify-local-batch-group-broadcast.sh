#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KESTRA_SOURCE_DIR="${KESTRA_SOURCE_DIR:-${ROOT_DIR}/../kestra}"
KESTRA_EXECUTABLE="${KESTRA_EXECUTABLE:-${KESTRA_SOURCE_DIR}/build/executable/kestra-2.0.0-SNAPSHOT}"
KESTRA_PLUGIN_SOURCE_DIR="${KESTRA_PLUGIN_SOURCE_DIR:-${KESTRA_SOURCE_DIR}/plugins}"
CONFIG_PATH="${ROOT_DIR}/local/broadcast/application.yaml"
FLOW_PATH="${ROOT_DIR}/kestra/flows-worker-routing/verify_batch_group_broadcast.yaml"
HTTP_PORT="${KESTRA_BROADCAST_HTTP_PORT:-28080}"
MANAGEMENT_PORT="${KESTRA_BROADCAST_MANAGEMENT_PORT:-28081}"
CONTROLLER_PORT="${KESTRA_BROADCAST_CONTROLLER_PORT:-25051}"
DB_PORT="${KESTRA_BROADCAST_DB_PORT:-55432}"
BUSINESS_DATE="${1:-${BUSINESS_DATE:-2026-07-15}}"
EXPECTED_WORKERS=2
USERNAME="admin@example.com"
PASSWORD="KestraBroadcast1234!"
RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kestra-broadcast.XXXXXX")"
POSTGRES_DIR="${RUNTIME_DIR}/postgres"
PLUGINS_DIR="${RUNTIME_DIR}/plugins"
STORAGE_DIR="${RUNTIME_DIR}/storage"
CONTROLLER_PID=""
WORKER_A_PID=""
WORKER_B_PID=""
STARTED_WORKER_PID=""
POSTGRES_STARTED=false

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for command in createdb curl initdb java jq pg_ctl pg_isready sort; do
  require_command "${command}"
done

if [[ ! -x "${KESTRA_EXECUTABLE}" ]]; then
  echo "Missing executable Kestra fork build: ${KESTRA_EXECUTABLE}" >&2
  echo "Build tacogips/kestra first with: ./gradlew writeExecutableJar --no-daemon" >&2
  exit 1
fi

shopt -s nullglob
shell_plugin_jars=("${KESTRA_PLUGIN_SOURCE_DIR}"/io_kestra_plugin__plugin-script-shell__*.jar)
if [[ "${#shell_plugin_jars[@]}" -ne 1 ]]; then
  echo "Expected exactly one Shell Commands plugin JAR in ${KESTRA_PLUGIN_SOURCE_DIR}." >&2
  exit 1
fi

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  for pid in "${WORKER_A_PID}" "${WORKER_B_PID}" "${CONTROLLER_PID}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      kill "${pid}" >/dev/null 2>&1 || true
    fi
  done

  for pid in "${WORKER_A_PID}" "${WORKER_B_PID}" "${CONTROLLER_PID}"; do
    if [[ -n "${pid}" ]]; then
      wait "${pid}" >/dev/null 2>&1 || true
    fi
  done

  if [[ "${POSTGRES_STARTED}" == true ]]; then
    pg_ctl -D "${POSTGRES_DIR}" -m fast stop >/dev/null 2>&1 || true
  fi

  rm -r "${RUNTIME_DIR}"
  exit "${status}"
}
trap cleanup EXIT INT TERM

mkdir -p "${PLUGINS_DIR}" "${STORAGE_DIR}"
ln -s "${shell_plugin_jars[0]}" "${PLUGINS_DIR}/$(basename "${shell_plugin_jars[0]}")"

initdb -D "${POSTGRES_DIR}" --username=kestra --auth=trust --encoding=UTF8 --no-locale \
  >"${RUNTIME_DIR}/initdb.log"
pg_ctl -D "${POSTGRES_DIR}" -l "${RUNTIME_DIR}/postgres.log" \
  -o "-h 127.0.0.1 -p ${DB_PORT}" start >/dev/null
POSTGRES_STARTED=true

for _ in {1..30}; do
  if pg_isready -h 127.0.0.1 -p "${DB_PORT}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
createdb -h 127.0.0.1 -p "${DB_PORT}" -U kestra kestra_broadcast

common_env=(
  KESTRA_BROADCAST_DB_PORT="${DB_PORT}"
  KESTRA_BROADCAST_STORAGE_PATH="${STORAGE_DIR}"
  KESTRA_CONTROLLER_PORT="${CONTROLLER_PORT}"
)

env "${common_env[@]}" \
  KESTRA_HTTP_PORT="${HTTP_PORT}" \
  KESTRA_MANAGEMENT_PORT="${MANAGEMENT_PORT}" \
  KESTRA_WORKER_GROUP_ID=controller \
  "${KESTRA_EXECUTABLE}" server standalone \
  --config "${CONFIG_PATH}" \
  --plugins "${PLUGINS_DIR}" \
  --worker-thread=1 \
  --no-tutorials \
  >"${RUNTIME_DIR}/controller.log" 2>&1 &
CONTROLLER_PID=$!

for _ in {1..120}; do
  if curl --silent --fail "http://127.0.0.1:${MANAGEMENT_PORT}/health" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "${CONTROLLER_PID}" >/dev/null 2>&1; then
    echo "Kestra controller exited during startup." >&2
    tail -100 "${RUNTIME_DIR}/controller.log" >&2
    exit 1
  fi
  sleep 1
done

if ! curl --silent --fail "http://127.0.0.1:${MANAGEMENT_PORT}/health" >/dev/null 2>&1; then
  echo "Kestra controller health endpoint did not become ready." >&2
  tail -100 "${RUNTIME_DIR}/controller.log" >&2
  exit 1
fi

start_broadcast_worker() {
  local member_name="$1"
  local log_path="$2"

  env "${common_env[@]}" \
    KESTRA_HTTP_PORT=0 \
    KESTRA_MANAGEMENT_PORT=0 \
    KESTRA_WORKER_GROUP_ID=broadcast-batch \
    POD_NAME="${member_name}" \
    "${KESTRA_EXECUTABLE}" server worker \
    --config "${CONFIG_PATH}" \
    --plugins "${PLUGINS_DIR}" \
    --thread=1 \
    >"${log_path}" 2>&1 &
  STARTED_WORKER_PID=$!
}

start_broadcast_worker batch-worker-a "${RUNTIME_DIR}/worker-a.log"
WORKER_A_PID="${STARTED_WORKER_PID}"
start_broadcast_worker batch-worker-b "${RUNTIME_DIR}/worker-b.log"
WORKER_B_PID="${STARTED_WORKER_PID}"

for _ in {1..60}; do
  registered_workers="$(
    grep -c "workerGroup='broadcast-batch'.*workerQueueId=gke-small" \
      "${RUNTIME_DIR}/controller.log" 2>/dev/null || true
  )"
  if [[ "${registered_workers}" -ge "${EXPECTED_WORKERS}" ]]; then
    break
  fi
  sleep 1
done

if [[ "${registered_workers:-0}" -lt "${EXPECTED_WORKERS}" ]]; then
  echo "Expected two registered broadcast-batch workers." >&2
  tail -100 "${RUNTIME_DIR}/controller.log" >&2
  exit 1
fi

url="http://127.0.0.1:${HTTP_PORT}"
response_file="${RUNTIME_DIR}/flow-response.json"
http_status="$(
  curl --silent --show-error \
    -u "${USERNAME}:${PASSWORD}" \
    -o "${response_file}" \
    -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/x-yaml' \
    --data-binary @"${FLOW_PATH}" \
    "${url}/api/v1/main/flows"
)"

if [[ ! "${http_status}" =~ ^2 ]]; then
  echo "Broadcast flow registration failed with HTTP ${http_status}." >&2
  jq . "${response_file}" >&2
  exit 1
fi

execution_response="$(
  KESTRA_BASIC_AUTH_USERNAME="${USERNAME}" \
    KESTRA_BASIC_AUTH_PASSWORD="${PASSWORD}" \
    NAMESPACE=playground.worker_routing \
    "${ROOT_DIR}/scripts/run-flow.sh" \
      verify_batch_group_broadcast "${BUSINESS_DATE}" "${url}"
)"
execution_id="$(jq -er '.id' <<<"${execution_response}")"
execution_json=""
execution_state=""

for _ in {1..120}; do
  execution_json="$(
    curl --silent --show-error --fail \
      -u "${USERNAME}:${PASSWORD}" \
      "${url}/api/v1/main/executions/${execution_id}"
  )"
  execution_state="$(jq -r '.state.current // empty' <<<"${execution_json}")"

  case "${execution_state}" in
    SUCCESS)
      break
      ;;
    FAILED | WARNING | KILLED | CANCELLED)
      echo "Broadcast execution ${execution_id} ended with ${execution_state}." >&2
      jq '.taskRunList' <<<"${execution_json}" >&2
      exit 1
      ;;
  esac
  sleep 1
done

if [[ "${execution_state}" != SUCCESS ]]; then
  echo "Broadcast execution ${execution_id} did not finish." >&2
  exit 1
fi

task_run_id="$(
  jq -er '[.taskRunList[] | select(.taskId == "broadcast_to_batch_group")][-1].id' \
    <<<"${execution_json}"
)"
outputs_json="$(
  curl --silent --show-error --fail \
    -u "${USERNAME}:${PASSWORD}" \
    "${url}/api/v1/main/outputs/${execution_id}/${task_run_id}"
)"
logs_json="$(
  curl --silent --show-error --fail \
    -u "${USERNAME}:${PASSWORD}" \
    "${url}/api/v1/main/logs/${execution_id}"
)"

if [[ "$(jq -er 'length' <<<"${outputs_json}")" -ne "${EXPECTED_WORKERS}" ]]; then
  echo "Expected two worker-keyed outputs." >&2
  jq 'keys' <<<"${outputs_json}" >&2
  exit 1
fi

mapfile -t members < <(
  jq -r '
    (if type == "array" then . else (.results // []) end)[]
    | select(.taskId == "broadcast_to_batch_group")
    | (.message // "")
    | split("\n")[]
    | select(. == "batch_group_member=batch-worker-a" or . == "batch_group_member=batch-worker-b")
    | sub("^batch_group_member="; "")
  ' <<<"${logs_json}" | sort -u
)

if [[ "${members[*]}" != "batch-worker-a batch-worker-b" ]]; then
  echo "Expected batch-worker-a and batch-worker-b in the broadcast logs." >&2
  printf 'member=%s\n' "${members[@]}" >&2
  exit 1
fi

echo "Batch-group broadcast execution ${execution_id} succeeded."
printf 'member=%s\n' "${members[@]}"
mapfile -t worker_ids < <(jq -r 'keys[]' <<<"${outputs_json}")
printf 'output_worker_id=%s\n' "${worker_ids[@]}"
