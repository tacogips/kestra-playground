#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
ZONE="${ZONE:-asia-northeast1-a}"
KESTRA_IMAGE="${KESTRA_IMAGE:-}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Missing required environment variable: PROJECT_ID or GCP_PROJECT_ID" >&2
  exit 1
fi

if [[ -z "${KESTRA_IMAGE}" ]]; then
  KESTRA_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/kestra-playground/kestra-oss-worker-routing:oss-worker-routing"
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command gcloud
require_command jq
require_command tofu

export KESTRA_IMAGE
export TF_VAR_zone="${TF_VAR_zone:-${ZONE}}"
export GKE_WORKER_ENABLED=true
# This entrypoint is specifically for the routed topology. Do not allow an
# inherited value from direnv or a generic CI environment to disable any of
# the controller, GCE-routed, or Kubernetes-routed workers it requires.
export LIVE_GKE_CONTROLLER_WORKER_ENABLED=false
export LIVE_GKE_ROUTED_WORKERS_ENABLED=true
# Route the public HTTPS ingress through the resident activator. It wakes the
# PostgreSQL StatefulSet first, then the Kestra control plane and routed workers,
# and parks them in the reverse order after the idle window.
export LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED=true
export LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED=true
export LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED=true
export LIVE_GKE_DATABASE_AUTOSCALE_ENABLED=true
export LIVE_GKE_ROUTED_K8S_WORKER_IDLE_SECONDS="${LIVE_GKE_ROUTED_K8S_WORKER_IDLE_SECONDS:-300}"
export LIVE_GKE_ROUTED_K8S_WORKER_ACTIVATOR_POLL_SECONDS="${LIVE_GKE_ROUTED_K8S_WORKER_ACTIVATOR_POLL_SECONDS:-5}"

echo "Deploying shared-backend OSS routed Kestra on GKE with GCE workers"
TARGET_ENVIRONMENT=k8s scripts/deploy-live-environments.sh

gcloud container clusters get-credentials kestra-dev \
  --region "${REGION}" \
  --project "${PROJECT_ID}"

mapfile -t worker_instances < <(
  tofu -chdir=infra/terraform/gke-dev output -json gce_worker_instances \
    | jq -r '.[]'
)

for instance in "${worker_instances[@]}"; do
  echo "Resetting ${instance} so the routed worker startup script is applied"
  gcloud compute instances reset "${instance}" \
    --zone "${ZONE}" \
    --project "${PROJECT_ID}" \
    --quiet
done

echo "Shared-backend routed live deployment finished."
