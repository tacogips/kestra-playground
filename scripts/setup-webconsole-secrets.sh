#!/usr/bin/env bash
# Registers the web console runtime values in Secret Manager.
# All values come from the environment (kinko locally, CI secrets in automation);
# nothing here is read from or written to git-tracked files.
#
# Required environment variables:
#   PROJECT_ID (or GCP_PROJECT_ID)
#   WEBCONSOLE_ALLOWED_EMAILS            comma-separated Google emails allowed to sign in
#   WEBCONSOLE_GOOGLE_CLIENT_ID          OAuth 2.0 web client ID
#   WEBCONSOLE_GOOGLE_CLIENT_SECRET      OAuth 2.0 web client secret
#   WEBCONSOLE_KESTRA_URL                on-premise Kestra API base URL
#   WEBCONSOLE_KESTRA_BASIC_AUTH_USERNAME
#   WEBCONSOLE_KESTRA_BASIC_AUTH_PASSWORD
# Optional:
#   WEBCONSOLE_SESSION_SECRET            generated with openssl when unset
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:?Set PROJECT_ID or GCP_PROJECT_ID}}"
SESSION_SECRET="${WEBCONSOLE_SESSION_SECRET:-$(openssl rand -hex 32)}"

upsert_secret() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    echo "Refusing to store empty value for secret ${name}" >&2
    exit 1
  fi
  if ! gcloud secrets describe "${name}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud secrets create "${name}" --project "${PROJECT_ID}" --replication-policy automatic
  fi
  printf '%s' "${value}" |
    gcloud secrets versions add "${name}" --project "${PROJECT_ID}" --data-file=-
  echo "Stored secret ${name}"
}

upsert_secret webconsole-allowed-emails "${WEBCONSOLE_ALLOWED_EMAILS:?}"
upsert_secret webconsole-google-client-id "${WEBCONSOLE_GOOGLE_CLIENT_ID:?}"
upsert_secret webconsole-google-client-secret "${WEBCONSOLE_GOOGLE_CLIENT_SECRET:?}"
upsert_secret webconsole-session-secret "${SESSION_SECRET}"
upsert_secret webconsole-kestra-url "${WEBCONSOLE_KESTRA_URL:?}"
upsert_secret webconsole-kestra-basic-auth-username "${WEBCONSOLE_KESTRA_BASIC_AUTH_USERNAME:?}"
upsert_secret webconsole-kestra-basic-auth-password "${WEBCONSOLE_KESTRA_BASIC_AUTH_PASSWORD:?}"

echo "All web console secrets registered in project ${PROJECT_ID}."
