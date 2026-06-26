#!/usr/bin/env bash
set -euo pipefail

LIVE_CONFIG_DIR="${LIVE_CONFIG_DIR:-infra/live/dev}"

require_value() {
  local name="$1"
  local value="$2"

  if [[ -z "${value}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

project_id="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
domain_name="${LIVE_DOMAIN_NAME:-}"
cloudflare_zone_id="${CLOUDFLARE_ZONE_ID:-${LIVE_CLOUDFLARE_ZONE_ID:-}}"
state_bucket="${TOFU_STATE_BUCKET:-${LIVE_TOFU_STATE_BUCKET:-}}"
dns_provider="${LIVE_DNS_PROVIDER:-cloudflare}"
cloudflare_dns_proxied="${CLOUDFLARE_DNS_PROXIED:-${LIVE_CLOUDFLARE_DNS_PROXIED:-false}}"
cloud_armor_rate_limit_requests="${CLOUD_ARMOR_RATE_LIMIT_REQUESTS_PER_INTERVAL:-300}"
cloud_armor_rate_limit_interval="${CLOUD_ARMOR_RATE_LIMIT_INTERVAL_SEC:-60}"
cloud_armor_preview="${CLOUD_ARMOR_PREVIEW:-false}"
cloud_armor_security_policy_name="${CLOUD_ARMOR_SECURITY_POLICY_NAME:-}"
cloud_armor_security_policy_self_link="${CLOUD_ARMOR_SECURITY_POLICY_SELF_LINK:-}"
live_gke_external_gce_worker_enabled="${LIVE_GKE_EXTERNAL_GCE_WORKER_ENABLED:-false}"
live_gke_external_gce_worker_group_key="${LIVE_GKE_EXTERNAL_GCE_WORKER_GROUP_KEY:-gce-heavy}"
live_gke_external_gce_worker_machine_type="${LIVE_GKE_EXTERNAL_GCE_WORKER_MACHINE_TYPE:-e2-standard-4}"
live_gke_external_gce_worker_gpu_type="${LIVE_GKE_EXTERNAL_GCE_WORKER_GPU_TYPE:-}"
live_gke_external_gce_worker_gpu_count="${LIVE_GKE_EXTERNAL_GCE_WORKER_GPU_COUNT:-0}"

require_value PROJECT_ID "$project_id"
require_value LIVE_DOMAIN_NAME "$domain_name"
require_value CLOUDFLARE_ZONE_ID "$cloudflare_zone_id"
require_value TOFU_STATE_BUCKET "$state_bucket"

mkdir -p "$LIVE_CONFIG_DIR"

write_tfvars() {
  local file="$1"
  local environment_name="$2"
  local subdomain="$3"
  local policy_field="$4"
  local policy_value="$5"

  cat >"${LIVE_CONFIG_DIR}/${file}" <<EOF
project_id = "${project_id}"

domain_name      = "${domain_name}"
environment_name = "${environment_name}"
subdomain        = "${subdomain}"
dns_provider     = "${dns_provider}"

cloudflare_zone_id     = "${cloudflare_zone_id}"
cloudflare_dns_proxied = ${cloudflare_dns_proxied}
${policy_field} = "${policy_value}"
EOF
}

write_cloud_armor_tfvars() {
  cat >"${LIVE_CONFIG_DIR}/cloud-armor.tfvars" <<EOF
project_id = "${project_id}"

rate_limit_requests_per_interval = ${cloud_armor_rate_limit_requests}
rate_limit_interval_sec          = ${cloud_armor_rate_limit_interval}
blocked_source_ranges            = []
preview                          = ${cloud_armor_preview}
EOF
}

write_backend() {
  local file="$1"

  cat >"${LIVE_CONFIG_DIR}/${file}" <<EOF
bucket = "${state_bucket}"
EOF
}

write_cloud_armor_tfvars
write_tfvars gce-single.tfvars "${LIVE_GCE_SINGLE_ENVIRONMENT_NAME:-gce-compose}" "${LIVE_GCE_SINGLE_SUBDOMAIN:-gce-compose}" \
  "cloud_armor_security_policy_self_link" "${cloud_armor_security_policy_self_link}"
write_tfvars gce-cluster.tfvars "${LIVE_GCE_CLUSTER_ENVIRONMENT_NAME:-gce-container}" "${LIVE_GCE_CLUSTER_SUBDOMAIN:-gce-container}" \
  "cloud_armor_security_policy_self_link" "${cloud_armor_security_policy_self_link}"
write_tfvars gke-dev.tfvars "${LIVE_GKE_ENVIRONMENT_NAME:-k8s}" "${LIVE_GKE_SUBDOMAIN:-k8s}" \
  "cloud_armor_security_policy_name" "${cloud_armor_security_policy_name}"

cat >>"${LIVE_CONFIG_DIR}/gke-dev.tfvars" <<EOF

external_gce_worker_enabled      = ${live_gke_external_gce_worker_enabled}
external_gce_worker_group_key    = "${live_gke_external_gce_worker_group_key}"
external_gce_worker_machine_type = "${live_gke_external_gce_worker_machine_type}"
external_gce_worker_gpu_type     = "${live_gke_external_gce_worker_gpu_type}"
external_gce_worker_gpu_count    = ${live_gke_external_gce_worker_gpu_count}
EOF

write_backend cloud-armor.backend.hcl
write_backend gce-single.backend.hcl
write_backend gce-cluster.backend.hcl
write_backend gke-dev.backend.hcl
write_backend github-actions.backend.hcl
