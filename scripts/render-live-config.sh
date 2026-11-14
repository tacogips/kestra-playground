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
  local extra_body="${6:-}"

  cat >"${LIVE_CONFIG_DIR}/${file}" <<EOF
project_id = "${project_id}"

domain_name      = "${domain_name}"
environment_name = "${environment_name}"
subdomain        = "${subdomain}"
dns_provider     = "${dns_provider}"

cloudflare_zone_id     = "${cloudflare_zone_id}"
cloudflare_dns_proxied = ${cloudflare_dns_proxied}
${policy_field} = "${policy_value}"
${extra_body}
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

gke_tfvars_extra_body() {
  if [[ "${LIVE_GKE_ROUTED_WORKERS_ENABLED:-false}" == "true" ]]; then
    cat <<EOF
controller_worker_enabled      = ${LIVE_GKE_CONTROLLER_WORKER_ENABLED:-true}
controller_worker_machine_type = "${LIVE_GKE_CONTROLLER_WORKER_MACHINE_TYPE:-e2-small}"
controller_worker_threads      = ${LIVE_GKE_CONTROLLER_WORKER_THREADS:-4}
routed_workers = {
  gce-a = {
    worker_group_id = "${LIVE_GKE_ROUTED_WORKER_A_GROUP_ID:-gce-a}"
    machine_type    = "${LIVE_GKE_ROUTED_WORKER_MACHINE_TYPE:-${LIVE_GKE_EXTERNAL_GCE_WORKER_MACHINE_TYPE:-e2-small}}"
    threads         = ${LIVE_GKE_ROUTED_WORKER_THREADS:-2}
  }
  gce-b = {
    worker_group_id = "${LIVE_GKE_ROUTED_WORKER_B_GROUP_ID:-gce-b}"
    machine_type    = "${LIVE_GKE_ROUTED_WORKER_MACHINE_TYPE:-${LIVE_GKE_EXTERNAL_GCE_WORKER_MACHINE_TYPE:-e2-small}}"
    threads         = ${LIVE_GKE_ROUTED_WORKER_THREADS:-2}
  }
}
EOF
    return
  fi

  cat <<EOF
controller_worker_enabled      = ${LIVE_GKE_CONTROLLER_WORKER_ENABLED:-true}
controller_worker_machine_type = "${LIVE_GKE_CONTROLLER_WORKER_MACHINE_TYPE:-e2-small}"
controller_worker_threads      = ${LIVE_GKE_CONTROLLER_WORKER_THREADS:-4}
routed_workers                 = {}
EOF
}

write_cloud_armor_tfvars
write_tfvars gce-single.tfvars "${LIVE_GCE_SINGLE_ENVIRONMENT_NAME:-gce-compose}" "${LIVE_GCE_SINGLE_SUBDOMAIN:-gce-compose}" \
  "cloud_armor_security_policy_self_link" "${cloud_armor_security_policy_self_link}"
write_tfvars gce-cluster.tfvars "${LIVE_GCE_CLUSTER_ENVIRONMENT_NAME:-gce-container}" "${LIVE_GCE_CLUSTER_SUBDOMAIN:-gce-container}" \
  "cloud_armor_security_policy_self_link" "${cloud_armor_security_policy_self_link}" \
  "cluster_size = ${LIVE_GCE_CLUSTER_SIZE:-2}"
write_tfvars gke-dev.tfvars "${LIVE_GKE_ENVIRONMENT_NAME:-k8s}" "${LIVE_GKE_SUBDOMAIN:-k8s}" \
  "cloud_armor_security_policy_name" "${cloud_armor_security_policy_name}" \
  "$(gke_tfvars_extra_body)"

write_backend cloud-armor.backend.hcl
write_backend gce-single.backend.hcl
write_backend gce-cluster.backend.hcl
write_backend gke-dev.backend.hcl
write_backend github-actions.backend.hcl
