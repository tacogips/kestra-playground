#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM="${1:?Usage: scripts/deploy-batch-group.sh <ec|affiliate> [kestra-url]}"
EXPLICIT_URL="${2:-}"

case "${SYSTEM}" in
  ec)
    FLOW_DIR="batch-groups/ec/flows"
    DEFAULT_LOCAL_URL="http://localhost:8080"
    ;;
  affiliate)
    # The affiliate batch group always targets a Kestra built from the official
    # kestra/kestra distribution, never a tacogips/kestra fork build.
    FLOW_DIR="batch-groups/affiliate/flows"
    DEFAULT_LOCAL_URL="http://localhost:8082"
    ;;
  *)
    echo "Unknown batch group: ${SYSTEM}" >&2
    echo "Use one of: ec, affiliate" >&2
    exit 1
    ;;
esac

ENVIRONMENT="${BATCH_GROUP_ENVIRONMENT:-}"
if [[ -z "${ENVIRONMENT}" ]]; then
  if [[ -n "${PROJECT_ID:-${GCP_PROJECT_ID:-}}" || -n "${LIVE_DOMAIN_NAME:-}" ]]; then
    ENVIRONMENT="gcp"
  else
    ENVIRONMENT="local"
  fi
fi
ENV_FILE="${BATCH_GROUP_ENV_FILE:-batch-groups/${SYSTEM}/config/envs/${ENVIRONMENT}.env}"
if [[ ! -f "${ENV_FILE}" && -f "${ENV_FILE}.example" ]]; then
  ENV_FILE="${ENV_FILE}.example"
fi
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
fi

case "${SYSTEM}" in
  ec)
    DEPLOY_URL="${EXPLICIT_URL:-${EC_KESTRA_DEPLOY_URL:-${KESTRA_DEPLOY_URL:-}}}"
    LIVE_SUBDOMAIN="${LIVE_EC_KESTRA_SUBDOMAIN:-${LIVE_KESTRA_SUBDOMAIN:-k8s}}"
    AUTH_SECRET_PREFIX="${EC_KESTRA_AUTH_SECRET_PREFIX:-${KESTRA_AUTH_SECRET_PREFIX:-kestra-dev-gke}}"
    ;;
  affiliate)
    DEPLOY_URL="${EXPLICIT_URL:-${AFFILIATE_KESTRA_DEPLOY_URL:-${KESTRA_DEPLOY_URL:-}}}"
    LIVE_SUBDOMAIN="${LIVE_AFFILIATE_KESTRA_SUBDOMAIN:-${LIVE_KESTRA_SUBDOMAIN:-affiliate-kestra}}"
    AUTH_SECRET_PREFIX="${AFFILIATE_KESTRA_AUTH_SECRET_PREFIX:-${KESTRA_AUTH_SECRET_PREFIX:-kestra-affiliate}}"
    ;;
esac

if [[ -z "${DEPLOY_URL}" ]]; then
  if [[ -n "${LIVE_DOMAIN_NAME:-}" ]]; then
    DEPLOY_URL="https://${LIVE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
  else
    DEPLOY_URL="${DEFAULT_LOCAL_URL}"
  fi
fi

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
if [[ "${KESTRA_AUTH_SOURCE:-environment}" == "secret-manager" ]]; then
  if [[ -z "${PROJECT_ID}" ]]; then
    echo "KESTRA_AUTH_SOURCE=secret-manager requires PROJECT_ID or GCP_PROJECT_ID" >&2
    exit 1
  fi
  if ! command -v gcloud >/dev/null 2>&1; then
    echo "KESTRA_AUTH_SOURCE=secret-manager requires gcloud" >&2
    exit 1
  fi
  export KESTRA_BASIC_AUTH_USERNAME
  export KESTRA_BASIC_AUTH_PASSWORD
  KESTRA_BASIC_AUTH_USERNAME="$(
    gcloud secrets versions access latest \
      --project="${PROJECT_ID}" \
      --secret="${AUTH_SECRET_PREFIX}-kestra-basic-auth-username"
  )"
  KESTRA_BASIC_AUTH_PASSWORD="$(
    gcloud secrets versions access latest \
      --project="${PROJECT_ID}" \
      --secret="${AUTH_SECRET_PREFIX}-kestra-basic-auth-password"
  )"
fi
if [[ -z "${KESTRA_BASIC_AUTH_USERNAME:-}" || -z "${KESTRA_BASIC_AUTH_PASSWORD:-}" ]]; then
  echo "Missing Kestra Basic Auth credentials" >&2
  exit 1
fi

WORK_FLOW_DIR=""
cleanup() {
  if [[ -n "${WORK_FLOW_DIR}" ]]; then
    rm -rf "${WORK_FLOW_DIR}"
  fi
}
trap cleanup EXIT INT TERM

# The GKE environment scales to zero, so the first request only wakes it up.
# Wait for the endpoint before probing its version, otherwise the probe reads the
# activator's 502/503 and the wrong flow variant is deployed.
wait_for_endpoint() {
  local attempts="${KESTRA_DEPLOY_WAIT_ATTEMPTS:-60}"
  local delay="${KESTRA_DEPLOY_WAIT_DELAY:-10}"
  local status

  for _ in $(seq 1 "${attempts}"); do
    status="$(
      curl --silent --output /dev/null --write-out '%{http_code}' --max-time 30 \
        -u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
        "${DEPLOY_URL%/}/api/v1/configs"
    )" || status="000"

    if [[ "${status}" == "200" ]]; then
      return 0
    fi
    echo "Endpoint ${DEPLOY_URL} answered HTTP ${status}; waiting ${delay}s for it to start."
    sleep "${delay}"
  done

  echo "Endpoint ${DEPLOY_URL} did not become ready." >&2
  return 1
}

# The affiliate notification flow is not portable across Kestra lineages: the
# canonical flow scopes its trigger with the 1.x `conditions` block, which
# Kestra 2 rejects with `Unrecognized field "conditions"`, and the Kestra 2
# variant needs a fork-only workerSelector the 1.x distribution does not know.
# Swap in the matching variant when the endpoint is Kestra 2 or newer.
if [[ "${SYSTEM}" == "affiliate" ]]; then
  wait_for_endpoint
  kestra_major="$(
    curl --silent --show-error --fail \
      -u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
      "${DEPLOY_URL%/}/api/v1/configs" |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["version"].split(".")[0])'
  )" || kestra_major=""

  if [[ -n "${kestra_major}" && "${kestra_major}" != "1" ]]; then
    echo "Endpoint reports Kestra ${kestra_major}; using the Kestra 2 notification variant."
    WORK_FLOW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kestra-affiliate-deploy.XXXXXX")"
    for flow in "${FLOW_DIR}"/*.yaml; do
      case "$(basename "${flow}")" in
        notify_affiliate_execution_result.yaml) continue ;;
        *) cp "${flow}" "${WORK_FLOW_DIR}/" ;;
      esac
    done
    cp kestra/flows-notification-affiliate/*.yaml "${WORK_FLOW_DIR}/"
    FLOW_DIR="${WORK_FLOW_DIR}"
  fi
fi

echo "Deploying ${SYSTEM} flows from ${FLOW_DIR} to ${DEPLOY_URL}"
"${SCRIPT_DIR}/register-flows.sh" "${DEPLOY_URL}" "${FLOW_DIR}"
echo "Deployed ${SYSTEM} batch group flows."
