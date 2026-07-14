#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM="${1:?Usage: scripts/deploy-batch-group.sh <ec|affiliate> [kestra-url]}"
EXPLICIT_URL="${2:-}"

case "${SYSTEM}" in
  ec)
    FLOW_DIR="batch-groups/ec/flows"
    DEFAULT_LOCAL_URL="http://localhost:8080"
    DEPLOY_URL="${EXPLICIT_URL:-${EC_KESTRA_DEPLOY_URL:-}}"
    LIVE_SUBDOMAIN="${LIVE_EC_KESTRA_SUBDOMAIN:-k8s}"
    AUTH_SECRET_PREFIX="${EC_KESTRA_AUTH_SECRET_PREFIX:-kestra-dev-gke}"
    ;;
  affiliate)
    # The affiliate batch group always targets a Kestra built from the official
    # kestra/kestra distribution, never a tacogips/kestra fork build.
    FLOW_DIR="batch-groups/affiliate/flows"
    DEFAULT_LOCAL_URL="http://localhost:8082"
    DEPLOY_URL="${EXPLICIT_URL:-${AFFILIATE_KESTRA_DEPLOY_URL:-}}"
    LIVE_SUBDOMAIN="${LIVE_AFFILIATE_KESTRA_SUBDOMAIN:-affiliate-kestra}"
    AUTH_SECRET_PREFIX="${AFFILIATE_KESTRA_AUTH_SECRET_PREFIX:-kestra-affiliate}"
    ;;
  *)
    echo "Unknown batch group: ${SYSTEM}" >&2
    echo "Use one of: ec, affiliate" >&2
    exit 1
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
if [[ -z "${KESTRA_BASIC_AUTH_USERNAME:-}" && -n "${PROJECT_ID}" ]] \
  && command -v gcloud >/dev/null 2>&1; then
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

echo "Deploying ${SYSTEM} flows from ${FLOW_DIR} to ${DEPLOY_URL}"
"${SCRIPT_DIR}/register-flows.sh" "${DEPLOY_URL}" "${FLOW_DIR}"
echo "Deployed ${SYSTEM} batch group flows."
