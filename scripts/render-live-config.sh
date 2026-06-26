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

require_value PROJECT_ID "$project_id"
require_value LIVE_DOMAIN_NAME "$domain_name"
require_value CLOUDFLARE_ZONE_ID "$cloudflare_zone_id"
require_value TOFU_STATE_BUCKET "$state_bucket"

mkdir -p "$LIVE_CONFIG_DIR"

write_tfvars() {
  local file="$1"
  local environment_name="$2"
  local subdomain="$3"

  cat >"${LIVE_CONFIG_DIR}/${file}" <<EOF
project_id = "${project_id}"

domain_name      = "${domain_name}"
environment_name = "${environment_name}"
subdomain        = "${subdomain}"
dns_provider     = "${dns_provider}"

cloudflare_zone_id     = "${cloudflare_zone_id}"
cloudflare_dns_proxied = ${cloudflare_dns_proxied}
EOF
}

write_backend() {
  local file="$1"

  cat >"${LIVE_CONFIG_DIR}/${file}" <<EOF
bucket = "${state_bucket}"
EOF
}

write_tfvars gce-single.tfvars "${LIVE_GCE_SINGLE_ENVIRONMENT_NAME:-gce-compose}" "${LIVE_GCE_SINGLE_SUBDOMAIN:-gce-compose}"
write_tfvars gce-cluster.tfvars "${LIVE_GCE_CLUSTER_ENVIRONMENT_NAME:-gce-container}" "${LIVE_GCE_CLUSTER_SUBDOMAIN:-gce-container}"
write_tfvars gke-dev.tfvars "${LIVE_GKE_ENVIRONMENT_NAME:-k8s}" "${LIVE_GKE_SUBDOMAIN:-k8s}"

write_backend gce-single.backend.hcl
write_backend gce-cluster.backend.hcl
write_backend gke-dev.backend.hcl
write_backend github-actions.backend.hcl
