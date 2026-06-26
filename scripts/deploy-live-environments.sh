#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
TARGET_ENVIRONMENT="${1:-${TARGET_ENVIRONMENT:-all}}"
LIVE_CONFIG_DIR="${LIVE_CONFIG_DIR:-infra/live/dev}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Missing required environment variable: PROJECT_ID or GCP_PROJECT_ID" >&2
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command gcloud
require_command tofu

scripts/render-live-config.sh

apply_tofu() {
  local root="$1"
  local var_file="$2"
  local backend_config="$3"
  local include_image="${4:-true}"
  local apply_args=(-input=false -auto-approve -var-file="${var_file}")

  if [[ "${include_image}" == "true" && -n "${KESTRA_IMAGE:-}" ]]; then
    apply_args+=("-var=kestra_image=${KESTRA_IMAGE}")
  fi

  echo "Applying ${root}"
  tofu -chdir="${root}" init -input=false -backend-config="${backend_config}"
  tofu -chdir="${root}" validate
  tofu -chdir="${root}" apply "${apply_args[@]}"
}

deploy_cloud_armor() {
  apply_tofu "infra/terraform/cloud-armor" "../../live/dev/cloud-armor.tfvars" "../../live/dev/cloud-armor.backend.hcl" false
  export CLOUD_ARMOR_SECURITY_POLICY_NAME
  export CLOUD_ARMOR_SECURITY_POLICY_SELF_LINK
  CLOUD_ARMOR_SECURITY_POLICY_NAME="$(tofu -chdir=infra/terraform/cloud-armor output -raw security_policy_name)"
  CLOUD_ARMOR_SECURITY_POLICY_SELF_LINK="$(tofu -chdir=infra/terraform/cloud-armor output -raw security_policy_self_link)"
  scripts/render-live-config.sh
}

deploy_gce_single() {
  apply_tofu "infra/terraform/gce-single" "../../live/dev/gce-single.tfvars" "../../live/dev/gce-single.backend.hcl"
  if [[ -n "${KESTRA_IMAGE:-}" ]]; then
    echo "Reconciling ${TARGET_ENVIRONMENT} single-VM instance group after image replacement"
    apply_tofu "infra/terraform/gce-single" "../../live/dev/gce-single.tfvars" "../../live/dev/gce-single.backend.hcl"
  fi
}

deploy_gce_cluster() {
  apply_tofu "infra/terraform/gce-cluster" "../../live/dev/gce-cluster.tfvars" "../../live/dev/gce-cluster.backend.hcl"
}

prepare_gke_external_worker_network_migration() {
  local root="infra/terraform/gke-dev"
  local var_file="../../live/dev/gke-dev.tfvars"
  local backend_config="../../live/dev/gke-dev.backend.hcl"
  local network_address='google_compute_network.external_gce_worker[0]'
  local firewall_address='google_compute_firewall.external_gce_worker_iap_ssh[0]'

  tofu -chdir="${root}" init -input=false -backend-config="${backend_config}" >/dev/null
  if ! tofu -chdir="${root}" state show "${network_address}" 2>/dev/null |
    grep -q 'auto_create_subnetworks[[:space:]]*=[[:space:]]*true'; then
    return 0
  fi

  echo "Destroying legacy external-worker firewall before replacing auto-mode worker VPC"
  tofu -chdir="${root}" destroy \
    -input=false \
    -auto-approve \
    -target="${firewall_address}" \
    -var-file="${var_file}"
}

deploy_gke_dev() {
  prepare_gke_external_worker_network_migration
  apply_tofu "infra/terraform/gke-dev" "../../live/dev/gke-dev.tfvars" "../../live/dev/gke-dev.backend.hcl"
  gcloud container clusters get-credentials kestra-dev \
    --region "${REGION}" \
    --project "${PROJECT_ID}"
  scripts/apply-gke-dev.sh
}

case "${TARGET_ENVIRONMENT}" in
  all)
    deploy_cloud_armor
    deploy_gce_single
    deploy_gce_cluster
    deploy_gke_dev
    ;;
  gce-compose | gce-single)
    deploy_cloud_armor
    deploy_gce_single
    ;;
  gce-container | gce-cluster)
    deploy_cloud_armor
    deploy_gce_cluster
    ;;
  k8s | gke-dev)
    deploy_cloud_armor
    deploy_gke_dev
    ;;
  *)
    echo "Unknown target environment: ${TARGET_ENVIRONMENT}" >&2
    echo "Use one of: all, gce-compose, gce-container, k8s" >&2
    exit 1
    ;;
esac
