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

echo "Deploying ${SYSTEM} flows from ${FLOW_DIR} to ${DEPLOY_URL}"
"${SCRIPT_DIR}/register-flows.sh" "${DEPLOY_URL}" "${FLOW_DIR}"
echo "Deployed ${SYSTEM} batch group flows."
