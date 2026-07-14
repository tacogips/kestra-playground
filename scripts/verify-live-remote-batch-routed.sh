#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}}"
REGION="${REGION:-asia-northeast1}"
KUBERNETES_NAMESPACE="${KUBERNETES_NAMESPACE:-kestra-dev}"
FLOW_NAMESPACE="playground.remote_batch"
BUSINESS_DATE="${1:-${BUSINESS_DATE:-2026-06-25}}"
LOCAL_PORT="${REMOTE_BATCH_ACTIVATOR_PORT:-18081}"
KESTRA_URL="http://127.0.0.1:${LOCAL_PORT}"
TEMP_DIR="$(mktemp -d)"
PORT_FORWARD_PID=""

cleanup() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
  rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT

for command in curl gcloud jq kubectl uv; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Missing required command: ${command}" >&2
    exit 1
  fi
done

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Missing PROJECT_ID/GCP_PROJECT_ID and no active gcloud project." >&2
  exit 1
fi

secret_value() {
  gcloud secrets versions access latest --project="${PROJECT_ID}" --secret="$1"
}

deployment_env() {
  local deployment="$1"
  local container="$2"
  local name="$3"

  kubectl -n "${KUBERNETES_NAMESPACE}" get deployment "${deployment}" \
    -o json \
    | jq -er \
      --arg container "${container}" \
      --arg name "${name}" \
      '.spec.template.spec.containers[] | select(.name == $container) | .env[] | select(.name == $name) | .value'
}

wait_for_replicas() {
  local expected="$1"
  local timeout_seconds="$2"
  shift 2
  local deployments=("$@")
  local deadline=$((SECONDS + timeout_seconds))
  local deployment
  local desired
  local ready
  local all_match

  while ((SECONDS < deadline)); do
    all_match=true
    for deployment in "${deployments[@]}"; do
      desired="$(kubectl -n "${KUBERNETES_NAMESPACE}" get deployment "${deployment}" -o jsonpath='{.spec.replicas}')"
      ready="$(kubectl -n "${KUBERNETES_NAMESPACE}" get deployment "${deployment}" -o jsonpath='{.status.readyReplicas}')"
      ready="${ready:-0}"
      if [[ "${desired}" != "${expected}" || "${ready}" != "${expected}" ]]; then
        all_match=false
        break
      fi
    done
    if [[ "${all_match}" == "true" ]]; then
      return 0
    fi
    sleep 5
  done

  echo "Deployments did not reach replicas=${expected}: ${deployments[*]}" >&2
  kubectl -n "${KUBERNETES_NAMESPACE}" get deployment "${deployments[@]}" >&2
  return 1
}

wait_for_ui() {
  local username="$1"
  local password="$2"

  for _ in {1..180}; do
    if curl --fail --silent --show-error --max-time 20 \
      -u "${username}:${password}" \
      "${KESTRA_URL}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  echo "Kestra did not become ready through the worker activator." >&2
  return 1
}

wait_for_warm_replicas() {
  local timeout_seconds="$1"
  shift
  local deployments=("$@")
  local deadline=$((SECONDS + timeout_seconds))
  local deployment
  local desired
  local ready
  local all_ready

  while ((SECONDS < deadline)); do
    curl --silent --max-time 10 \
      -u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
      "${KESTRA_URL}/" >/dev/null 2>&1 || true
    all_ready=true
    for deployment in "${deployments[@]}"; do
      desired="$(kubectl -n "${KUBERNETES_NAMESPACE}" get deployment "${deployment}" -o jsonpath='{.spec.replicas}')"
      ready="$(kubectl -n "${KUBERNETES_NAMESPACE}" get deployment "${deployment}" -o jsonpath='{.status.readyReplicas}')"
      ready="${ready:-0}"
      if [[ "${desired}" != "1" || "${ready}" != "1" ]]; then
        all_ready=false
        break
      fi
    done
    if [[ "${all_ready}" == "true" ]]; then
      return 0
    fi
    sleep 5
  done

  echo "Activator-managed Deployments did not become ready." >&2
  kubectl -n "${KUBERNETES_NAMESPACE}" get deployment "${deployments[@]}" >&2
  return 1
}

submit_flow() {
  local flow_id="$1"
  local bundle_path="$2"
  shift 2
  local form_args=(
    -F "batch_bundle=@${bundle_path};filename=$(basename "${bundle_path}")"
    -F "business_date=${BUSINESS_DATE}"
  )
  local item

  for item in "$@"; do
    form_args+=(-F "${item}")
  done

  curl --fail --silent --show-error \
    -u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
    -X POST \
    "${form_args[@]}" \
    "${KESTRA_URL}/api/v1/main/executions/${FLOW_NAMESPACE}/${flow_id}"
}

wait_for_execution() {
  local execution_id="$1"
  local expected_state="$2"
  local destination="$3"
  local execution_json
  local state

  for _ in {1..240}; do
    if ! execution_json="$(
      curl --fail --silent \
        -u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
        "${KESTRA_URL}/api/v1/main/executions/${execution_id}"
    )"; then
      sleep 2
      continue
    fi
    state="$(jq -r '.state.current // empty' <<<"${execution_json}")"
    case "${state}" in
      SUCCESS | FAILED | KILLED | WARNING)
        printf '%s\n' "${execution_json}" >"${destination}"
        if [[ "${state}" != "${expected_state}" ]]; then
          echo "Execution ${execution_id} ended with ${state}; expected ${expected_state}." >&2
          jq -r '.taskRunList // []' <<<"${execution_json}" >&2
          return 1
        fi
        return 0
        ;;
    esac
    sleep 5
  done

  echo "Execution ${execution_id} did not finish." >&2
  return 1
}

fetch_child_execution() {
  local parent_file="$1"
  local child_file="$2"
  local child_execution_id
  local parent_execution_id
  local parent_logs

  child_execution_id="$(
    jq -r '
      .taskRunList[]
      | select(.taskId == "run_remote_batch")
      | .outputs.executionId // empty
    ' \
      "${parent_file}"
  )"
  if [[ -z "${child_execution_id}" || "${child_execution_id}" == "null" ]]; then
    parent_execution_id="$(jq -er '.id' "${parent_file}")"
    parent_logs="$(
      curl --fail --silent --show-error \
        -u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
        "${KESTRA_URL}/api/v1/main/logs/${parent_execution_id}"
    )"
    child_execution_id="$(
      jq -er '
        (if type == "array" then . else (.results // []) end)
        | map(select(.message | contains("Created new execution")))
        | last
        | .message
        | capture("execution=\\\"(?<id>[^\\\"]+)").id
      ' <<<"${parent_logs}"
    )"
  fi
  for _ in {1..30}; do
    if curl --fail --silent \
      -u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
      "${KESTRA_URL}/api/v1/main/executions/${child_execution_id}" >"${child_file}"; then
      printf '%s' "${child_execution_id}"
      return 0
    fi
    sleep 2
  done
  echo "Child execution ${child_execution_id} was not readable." >&2
  return 1
}

fetch_execution_logs() {
  local execution_id="$1"
  local destination="$2"

  for _ in {1..30}; do
    if curl --fail --silent \
      -u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
      "${KESTRA_URL}/api/v1/main/logs/${execution_id}" \
      | jq '(if type == "array" then . else (.results // []) end)' >"${destination}"; then
      return 0
    fi
    sleep 2
  done
  echo "Logs for execution ${execution_id} were not readable." >&2
  return 1
}

assert_success() {
  local flow_id="$1"
  local expected_group="$2"
  local child_file="$3"
  local logs_file="$4"
  local task_id="execute_batch_${expected_group//-/_}"

  jq -e --arg expected_group "${expected_group}" --arg task_id "${task_id}" '
    .state.current == "SUCCESS"
    and any(.taskRunList[]; .taskId == $task_id and .state.current == "SUCCESS")
    and (.outputs.artifact | startswith("kestra:///"))
    and (.outputs.artifact_checksum | test("^[0-9a-f]{64}$"))
    and .outputs.worker_group == $expected_group
    and (.outputs.worker_pod | startswith("kestra-gke-worker-"))
  ' "${child_file}" >/dev/null
  jq -e --arg expected_group "${expected_group}" --arg task_id "${task_id}" '
    any(.[]; .taskId == $task_id and (.message | contains("progress phase=worker_ready group=" + $expected_group)))
    and any(.[]; .taskId == $task_id and (.message | contains("progress phase=complete")))
    and any(.[]; .taskId == $task_id and (.message | contains("progress phase=runtime_cleaned verified=true")))
  ' "${logs_file}" >/dev/null

  case "${flow_id}" in
    export_database_to_csv_routed)
      jq -e --arg task_id "${task_id}" '
        any(.[]; .taskId == $task_id and (.message | contains("progress phase=complete rows=3")))
      ' "${logs_file}" >/dev/null
      ;;
    parse_application_logs_routed)
      jq -e --arg task_id "${task_id}" '
        any(.[]; .taskId == $task_id and (.message | contains("progress phase=complete matched=3 malformed=1")))
      ' "${logs_file}" >/dev/null
      ;;
  esac
}

assert_failure() {
  local expected_group="$1"
  local child_file="$2"
  local logs_file="$3"
  local task_id="execute_batch_${expected_group//-/_}"

  jq -e --arg task_id "${task_id}" '
    .state.current == "FAILED"
    and any(.taskRunList[]; .taskId == $task_id and .state.current == "FAILED")
  ' "${child_file}" >/dev/null
  jq -e --arg task_id "${task_id}" '
    any(.[]; .taskId == $task_id and (.message | contains("batch_error type=FileNotFoundError")))
    and any(.[]; .taskId == $task_id and (.message | contains("progress phase=runtime_cleaned verified=true")))
    and all(.[]; (.message | contains("Failed to render output values")) | not)
  ' "${logs_file}" >/dev/null
}

run_and_assert() {
  local flow_id="$1"
  local expected_group="$2"
  local expected_state="$3"
  local bundle_path="$4"
  shift 4
  local response
  local parent_id
  local parent_file
  local child_id
  local child_file
  local logs_file

  response="$(submit_flow "${flow_id}" "${bundle_path}" "$@")"
  parent_id="$(jq -er '.id' <<<"${response}")"
  parent_file="${TEMP_DIR}/${parent_id}-parent.json"
  child_file="${TEMP_DIR}/${parent_id}-child.json"
  logs_file="${TEMP_DIR}/${parent_id}-logs.json"
  wait_for_execution "${parent_id}" "${expected_state}" "${parent_file}"
  child_id="$(fetch_child_execution "${parent_file}" "${child_file}")"
  fetch_execution_logs "${child_id}" "${logs_file}"

  if [[ "${expected_state}" == "SUCCESS" ]]; then
    assert_success "${flow_id}" "${expected_group}" "${child_file}" "${logs_file}"
  else
    assert_failure "${expected_group}" "${child_file}" "${logs_file}"
  fi

  echo "${flow_id}: parent=${parent_id} runner=${child_id} state=${expected_state}"
  jq -r '
    (.taskRunList // [])[]
    | [.taskId, .state.current, (.workerId // .worker.id // ""), (.outputs.vars.worker_pod // "")]
    | @tsv
  ' "${child_file}"
  jq -r '
    .[]
    | select(.message | contains("progress ") or contains("batch_error "))
    | [.taskId, .level, .message]
    | @tsv
  ' "${logs_file}"
}

gcloud container clusters get-credentials kestra-dev \
  --region "${REGION}" \
  --project "${PROJECT_ID}" >/dev/null

export KESTRA_BASIC_AUTH_USERNAME
export KESTRA_BASIC_AUTH_PASSWORD
KESTRA_BASIC_AUTH_USERNAME="$(secret_value kestra-dev-gke-kestra-basic-auth-username)"
KESTRA_BASIC_AUTH_PASSWORD="$(secret_value kestra-dev-gke-kestra-basic-auth-password)"

read -r -a managed_deployments <<<"$(
  deployment_env kestra-worker-activator scaler SCALE_DEPLOYMENTS
)"
idle_seconds="$(deployment_env kestra-worker-activator scaler IDLE_SECONDS)"
scale_timeout="${REMOTE_BATCH_SCALE_TIMEOUT:-$((idle_seconds + 180))}"

echo "Waiting for the scale-to-zero baseline: ${managed_deployments[*]}"
wait_for_replicas 0 "${scale_timeout}" "${managed_deployments[@]}"

kubectl -n "${KUBERNETES_NAMESPACE}" port-forward \
  --address 127.0.0.1 \
  service/kestra-worker-activator \
  "${LOCAL_PORT}:8080" \
  >"${TEMP_DIR}/port-forward.log" 2>&1 &
PORT_FORWARD_PID=$!

for _ in {1..30}; do
  if curl --silent --show-error --max-time 2 "${KESTRA_URL}/" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
    cat "${TEMP_DIR}/port-forward.log" >&2
    exit 1
  fi
  sleep 1
done

wait_for_ui "${KESTRA_BASIC_AUTH_USERNAME}" "${KESTRA_BASIC_AUTH_PASSWORD}"
wait_for_warm_replicas 900 "${managed_deployments[@]}"

BUNDLE_DIR="${TEMP_DIR}/bundles"
REMOTE_BATCH_ADAPTER=routed \
  REMOTE_BATCH_BUNDLE_DIR="${BUNDLE_DIR}" \
  REGISTER_FLOW_ATTEMPTS=18 \
  "${ROOT_DIR}/scripts/register-remote-batch-demo.sh" "${KESTRA_URL}"

run_and_assert \
  export_database_to_csv_routed \
  gke-small \
  SUCCESS \
  "${BUNDLE_DIR}/db_export.tar.gz"
run_and_assert \
  parse_application_logs_routed \
  gke-large \
  SUCCESS \
  "${BUNDLE_DIR}/log_parse.tar.gz"
run_and_assert \
  parse_application_logs_routed \
  gke-large \
  FAILED \
  "${BUNDLE_DIR}/log_parse.tar.gz" \
  "log_path=batches/log_parse/fixtures/missing.jsonl"

kill "${PORT_FORWARD_PID}"
wait "${PORT_FORWARD_PID}" 2>/dev/null || true
PORT_FORWARD_PID=""

echo "Waiting for the activator to park the verified topology again."
wait_for_replicas 0 "${scale_timeout}" "${managed_deployments[@]}"
echo "Verified cold wake-up, routed uv execution, artifacts, failure propagation, and scale-to-zero."
