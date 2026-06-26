#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
BUSINESS_DATE_INPUT="${1:-${BUSINESS_DATE:-}}"
LIVE_DOMAIN_NAME="${LIVE_DOMAIN_NAME:-}"
LIVE_GCE_CLUSTER_SUBDOMAIN="${LIVE_GCE_CLUSTER_SUBDOMAIN:-gce-container}"
LIVE_GKE_SUBDOMAIN="${LIVE_GKE_SUBDOMAIN:-k8s}"

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
        echo "Federated controller execution ${execution_id} succeeded."
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

gce_url="https://${LIVE_GCE_CLUSTER_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
gke_url="https://${LIVE_GKE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"

gce_username="$(secret_value kestra-cluster-dev-kestra-basic-auth-username)"
gce_password="$(secret_value kestra-cluster-dev-kestra-basic-auth-password)"
gke_username="$(secret_value kestra-dev-gke-kestra-basic-auth-username)"
gke_password="$(secret_value kestra-dev-gke-kestra-basic-auth-password)"

echo "=== Federated child: GCE (${gce_url}) ==="
export KESTRA_BASIC_AUTH_USERNAME="${gce_username}"
export KESTRA_BASIC_AUTH_PASSWORD="${gce_password}"
wait_for_ui "${gce_url}" "${gce_username}" "${gce_password}"
scripts/register-flows.sh "${gce_url}" kestra/flows

echo "=== Federated controller and child: GKE (${gke_url}) ==="
export KESTRA_BASIC_AUTH_USERNAME="${gke_username}"
export KESTRA_BASIC_AUTH_PASSWORD="${gke_password}"
wait_for_ui "${gke_url}" "${gke_username}" "${gke_password}"
scripts/register-flows.sh "${gke_url}" kestra/flows
scripts/register-flows.sh "${gke_url}" kestra/flows-federated

response="$(
  NAMESPACE=playground.ecommerce.controller \
    scripts/run-flow.sh run_federated_ecommerce_batch "${BUSINESS_DATE}" "${gke_url}"
)"
execution_id="$(jq -er '.id' <<<"${response}")"
echo "run_federated_ecommerce_batch: ${execution_id}"
wait_for_execution "${gke_url}" "${gke_username}" "${gke_password}" "${execution_id}"
