#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-example-project-id}"
REGION="${REGION:-asia-northeast1}"
TARGET_ENVIRONMENT="${1:-${TARGET_ENVIRONMENT:-all}}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command gcloud
require_command tofu

apply_tofu() {
  local root="$1"
  local var_file="$2"

  echo "Applying ${root}"
  tofu -chdir="${root}" init -input=false
  tofu -chdir="${root}" validate
  tofu -chdir="${root}" apply -input=false -auto-approve -var-file="${var_file}"
}

deploy_gce_single() {
  apply_tofu "infra/terraform/gce-single" "../../live/dev/gce-single.tfvars"
}

deploy_gce_cluster() {
  apply_tofu "infra/terraform/gce-cluster" "../../live/dev/gce-cluster.tfvars"
}

deploy_gke_dev() {
  apply_tofu "infra/terraform/gke-dev" "../../live/dev/gke-dev.tfvars"
  gcloud container clusters get-credentials kestra-dev \
    --region "${REGION}" \
    --project "${PROJECT_ID}"
  scripts/apply-gke-dev.sh
}

case "${TARGET_ENVIRONMENT}" in
  all)
    deploy_gce_single
    deploy_gce_cluster
    deploy_gke_dev
    ;;
  gce-compose | gce-single)
    deploy_gce_single
    ;;
  gce-container | gce-cluster)
    deploy_gce_cluster
    ;;
  k8s | gke-dev)
    deploy_gke_dev
    ;;
  *)
    echo "Unknown target environment: ${TARGET_ENVIRONMENT}" >&2
    echo "Use one of: all, gce-compose, gce-container, k8s" >&2
    exit 1
    ;;
esac
