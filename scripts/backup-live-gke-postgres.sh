#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
NAMESPACE="${NAMESPACE:-kestra-dev}"
BACKUP_BUCKET="${BACKUP_BUCKET:-}"

if [[ -z "$PROJECT_ID" || -z "$BACKUP_BUCKET" ]]; then
  echo "PROJECT_ID and BACKUP_BUCKET are required." >&2
  exit 1
fi

gcloud container clusters get-credentials kestra-dev \
  --region "$REGION" \
  --project "$PROJECT_ID"

kubectl -n "$NAMESPACE" scale statefulset/kestra-postgres --replicas=1 >/dev/null
kubectl -n "$NAMESPACE" rollout status statefulset/kestra-postgres --timeout=10m

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
chmod 700 "$temporary_directory"
backup_prefix="postgres-finalization/$(date -u +%Y%m%dT%H%M%SZ)"

for database in kestra ecommerce_ops; do
  dump_path="${temporary_directory}/${database}.dump"
  kubectl -n "$NAMESPACE" exec statefulset/kestra-postgres -- \
    pg_dump --username=kestra --dbname="$database" \
      --format=custom --no-owner --no-privileges >"$dump_path"
  chmod 600 "$dump_path"
  if [[ ! -s "$dump_path" ]]; then
    echo "PostgreSQL backup for ${database} is empty." >&2
    exit 1
  fi
  gcloud storage cp "$dump_path" \
    "gs://${BACKUP_BUCKET}/${backup_prefix}/${database}.dump" \
    --quiet
done

gcloud storage ls "gs://${BACKUP_BUCKET}/${backup_prefix}/"
echo "backup_prefix=gs://${BACKUP_BUCKET}/${backup_prefix}/"
