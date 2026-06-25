#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-example-project-id}"
TARGET_ENVIRONMENT="${1:-${TARGET_ENVIRONMENT:-all}}"
BUSINESS_DATE="${2:-${BUSINESS_DATE:-2026-06-25}}"
MODE="${3:-${MODE:-run-batch}}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command curl
require_command gcloud
require_command jq

secret_value() {
  local secret_name="$1"
  gcloud secrets versions access latest --project="${PROJECT_ID}" --secret="${secret_name}"
}

configure_gce_auth() {
  local prefix="$1"
  export KESTRA_BASIC_AUTH_USERNAME
  export KESTRA_BASIC_AUTH_PASSWORD
  KESTRA_BASIC_AUTH_USERNAME="$(secret_value "${prefix}-kestra-basic-auth-username")"
  KESTRA_BASIC_AUTH_PASSWORD="$(secret_value "${prefix}-kestra-basic-auth-password")"
}

configure_k8s_auth() {
  export KESTRA_BASIC_AUTH_USERNAME
  export KESTRA_BASIC_AUTH_PASSWORD
  KESTRA_BASIC_AUTH_USERNAME="$(secret_value kestra-dev-gke-kestra-basic-auth-username)"
  KESTRA_BASIC_AUTH_PASSWORD="$(secret_value kestra-dev-gke-kestra-basic-auth-password)"
}

wait_for_execution() {
  local url="$1"
  local execution_id="$2"
  local status_url="${url%/}/api/v1/main/executions/${execution_id}"
  local state=""

  for _ in {1..120}; do
    state="$(
      curl --fail --silent --show-error \
        -u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
        "${status_url}" | jq -r '.state.current // empty'
    )"

    case "${state}" in
      SUCCESS)
        echo "Execution ${execution_id} succeeded."
        return 0
        ;;
      FAILED | KILLED | WARNING)
        echo "Execution ${execution_id} ended with state ${state}." >&2
        return 1
        ;;
    esac

    sleep 5
  done

  echo "Execution ${execution_id} did not finish. Last state: ${state:-unknown}" >&2
  return 1
}

run_flow_and_wait() {
  local url="$1"
  local flow_id="$2"
  local response
  local execution_id

  response="$(scripts/run-flow.sh "${flow_id}" "${BUSINESS_DATE}" "${url}")"
  execution_id="$(jq -er '.id' <<<"${response}")"
  echo "${flow_id}: ${execution_id}"
  wait_for_execution "${url}" "${execution_id}"
}

wait_for_ui() {
  local url="$1"

  for _ in {1..120}; do
    if curl --fail --silent --show-error \
      -u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
      "${url%/}/ui/" >/dev/null; then
      return 0
    fi

    sleep 10
  done

  echo "Kestra UI did not become ready: ${url}" >&2
  return 1
}

verify_environment() {
  local name="$1"
  local url="$2"

  echo "=== ${name} (${url}) ==="
  wait_for_ui "${url}"
  scripts/register-flows.sh "${url}"

  if [[ "${MODE}" == "run-batch" ]]; then
    run_flow_and_wait "${url}" generate_ecommerce_mock_data
    run_flow_and_wait "${url}" build_ecommerce_daily_report
  fi
}

verify_gce_compose() {
  configure_gce_auth kestra-dev
  verify_environment gce-compose "https://gce-compose.example.com"
}

verify_gce_container() {
  configure_gce_auth kestra-cluster-dev
  verify_environment gce-container "https://gce-container.example.com"
}

verify_k8s() {
  configure_k8s_auth
  verify_environment k8s "https://k8s.example.com"
}

case "${MODE}" in
  health | run-batch) ;;
  *)
    echo "Unknown mode: ${MODE}" >&2
    echo "Use one of: health, run-batch" >&2
    exit 1
    ;;
esac

case "${TARGET_ENVIRONMENT}" in
  all)
    verify_gce_compose
    verify_gce_container
    verify_k8s
    ;;
  gce-compose | gce-single)
    verify_gce_compose
    ;;
  gce-container | gce-cluster)
    verify_gce_container
    ;;
  k8s | gke-dev)
    verify_k8s
    ;;
  *)
    echo "Unknown target environment: ${TARGET_ENVIRONMENT}" >&2
    echo "Use one of: all, gce-compose, gce-container, k8s" >&2
    exit 1
    ;;
esac
