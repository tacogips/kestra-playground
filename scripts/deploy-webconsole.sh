#!/usr/bin/env bash
# Builds and deploys the web console to Cloud Run from source, wiring runtime
# configuration from the Secret Manager entries created by
# scripts/setup-webconsole-secrets.sh. Google login is enforced inside the app,
# so the service itself allows unauthenticated ingress.
#
# Required environment variables:
#   PROJECT_ID (or GCP_PROJECT_ID)
# Optional:
#   REGION   (default: asia-northeast1)
#   SERVICE  (default: kestra-webconsole)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:?Set PROJECT_ID or GCP_PROJECT_ID}}"
REGION="${REGION:-asia-northeast1}"
SERVICE="${SERVICE:-kestra-webconsole}"
SERVICE_ACCOUNT_NAME="webconsole-run"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

SECRET_NAMES=(
  webconsole-allowed-emails
  webconsole-google-client-id
  webconsole-google-client-secret
  webconsole-session-secret
  webconsole-kestra-url
  webconsole-kestra-basic-auth-username
  webconsole-kestra-basic-auth-password
)

gcloud services enable run.googleapis.com cloudbuild.googleapis.com \
  secretmanager.googleapis.com artifactregistry.googleapis.com \
  --project "${PROJECT_ID}"

# The routed remote-batch flows take an execution-scoped source bundle as a
# FILE input; bake freshly built bundles into the console image.
"${REPO_ROOT}/scripts/build-remote-batch-bundles.sh" "${REPO_ROOT}/webconsole/bundles"

if ! gcloud iam service-accounts describe "${SERVICE_ACCOUNT}" \
  --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SERVICE_ACCOUNT_NAME}" \
    --project "${PROJECT_ID}" \
    --display-name "Kestra web console Cloud Run runtime"
fi

for secret in "${SECRET_NAMES[@]}"; do
  gcloud secrets add-iam-policy-binding "${secret}" \
    --project "${PROJECT_ID}" \
    --member "serviceAccount:${SERVICE_ACCOUNT}" \
    --role roles/secretmanager.secretAccessor >/dev/null
done

gcloud run deploy "${SERVICE}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --source "${REPO_ROOT}/webconsole" \
  --service-account "${SERVICE_ACCOUNT}" \
  --allow-unauthenticated \
  --min-instances 0 \
  --max-instances 2 \
  --memory 512Mi \
  --set-env-vars "^|^AUTH_MODE=google|KESTRA_TENANT=main|KESTRA_NAMESPACE=${KESTRA_NAMESPACE:-playground.remote_batch}|KESTRA_FLOW_IDS=${KESTRA_FLOW_IDS:-export_database_to_csv_routed,parse_application_logs_routed}|KESTRA_FLOW_BUNDLES=${KESTRA_FLOW_BUNDLES:-export_database_to_csv_routed=bundles/db_export.tar.gz,parse_application_logs_routed=bundles/log_parse.tar.gz}" \
  --set-secrets "ALLOWED_EMAILS=webconsole-allowed-emails:latest,GOOGLE_CLIENT_ID=webconsole-google-client-id:latest,GOOGLE_CLIENT_SECRET=webconsole-google-client-secret:latest,SESSION_SECRET=webconsole-session-secret:latest,KESTRA_URL=webconsole-kestra-url:latest,KESTRA_BASIC_AUTH_USERNAME=webconsole-kestra-basic-auth-username:latest,KESTRA_BASIC_AUTH_PASSWORD=webconsole-kestra-basic-auth-password:latest"

SERVICE_URL="$(gcloud run services describe "${SERVICE}" \
  --project "${PROJECT_ID}" --region "${REGION}" --format 'value(status.url)')"

gcloud run services update "${SERVICE}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --update-env-vars "APP_BASE_URL=${SERVICE_URL}"

echo
echo "Deployed: ${SERVICE_URL}"
echo "Ensure the OAuth client has this authorized redirect URI:"
echo "  ${SERVICE_URL}/auth/callback"
