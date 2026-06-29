#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Missing required environment variable: PROJECT_ID or GCP_PROJECT_ID" >&2
  exit 1
fi

echo "Deploying federated GCE child Kestra"
TARGET_ENVIRONMENT=gce-compose scripts/deploy-live-environments.sh

echo "Deploying federated second GCE child Kestra"
LIVE_GCE_CLUSTER_SIZE="${LIVE_GCE_CLUSTER_SIZE:-1}" \
  TARGET_ENVIRONMENT=gce-container scripts/deploy-live-environments.sh

echo "Deploying federated GKE controller Kestra"
GKE_WORKER_ENABLED=false TARGET_ENVIRONMENT=k8s scripts/deploy-live-environments.sh

gcloud container clusters get-credentials kestra-dev \
  --region "${REGION}" \
  --project "${PROJECT_ID}"

echo "Federated live deployment finished."
