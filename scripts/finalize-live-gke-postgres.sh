#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "Missing required environment variable: PROJECT_ID or GCP_PROJECT_ID" >&2
  exit 1
fi

scripts/render-live-config.sh
tofu -chdir=infra/terraform/gke-dev init \
  -input=false \
  -backend-config="../../live/dev/gke-dev.backend.hcl"

current_image="$(tofu -chdir=infra/terraform/gke-dev output -raw kestra_image)"
backup_bucket="$(tofu -chdir=infra/terraform/gke-dev output -raw gcs_bucket)"

BACKUP_BUCKET="$backup_bucket" scripts/backup-live-gke-postgres.sh

# Cloud SQL refuses to drop an owner user while its objects still exist. The
# instance deletion removes that user atomically, so stop managing the child
# user separately before applying removal of the parent instance.
if tofu -chdir=infra/terraform/gke-dev state list \
  | grep -Fxq 'google_sql_user.kestra'; then
  tofu -chdir=infra/terraform/gke-dev state rm google_sql_user.kestra
fi

export KESTRA_IMAGE="$current_image"
scripts/deploy-routed-live.sh
