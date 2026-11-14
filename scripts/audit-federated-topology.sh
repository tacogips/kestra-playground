#!/usr/bin/env bash
set -euo pipefail

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command ruby

controller_flow="kestra/flows-federated/run_federated_ecommerce_batch.yaml"

require_pattern() {
  local pattern="$1"
  local file="$2"

  if ! grep -qE "$pattern" "$file"; then
    echo "Expected pattern not found in ${file}: ${pattern}" >&2
    exit 1
  fi
}

reject_pattern() {
  local pattern="$1"
  local file="$2"

  if grep -qE "$pattern" "$file"; then
    echo "Unexpected pattern found in ${file}: ${pattern}" >&2
    exit 1
  fi
}

ruby -ryaml -e '
  doc = YAML.load_file(ARGV.fetch(0))
  abort("controller namespace mismatch") unless doc.fetch("namespace") == "playground.ecommerce.controller"
  task_ids = doc.fetch("tasks").map { |task| task.fetch("id") }
  raw_batch_task_ids = %w[
    generate_ecommerce_mock_data
    build_ecommerce_customer_segments
    build_ecommerce_daily_report
  ]
  found = task_ids & raw_batch_task_ids
  abort("controller contains raw batch task IDs: #{found.join(", ")}") unless found.empty?
' "$controller_flow"

require_pattern 'playground\.ecommerce\.server_gce_a/generate_ecommerce_mock_data' "$controller_flow"
require_pattern 'playground\.ecommerce\.server_gce_a/build_ecommerce_customer_segments' "$controller_flow"
require_pattern 'playground\.ecommerce\.server_gce_b/generate_ecommerce_mock_data' "$controller_flow"
require_pattern 'playground\.ecommerce\.server_gce_b/build_ecommerce_daily_report' "$controller_flow"
reject_pattern 'playground\.ecommerce\.server_gke' "$controller_flow"
reject_pattern 'federated_gke_worker' "$controller_flow"
reject_pattern 'federated_gce_worker' "$controller_flow"

require_pattern 'TARGET_ENVIRONMENT=gce-compose' scripts/deploy-federated-live.sh
require_pattern 'LIVE_GCE_CLUSTER_SIZE="\$\{LIVE_GCE_CLUSTER_SIZE:-1\}"' scripts/deploy-federated-live.sh
require_pattern 'TARGET_ENVIRONMENT=gce-container' scripts/deploy-federated-live.sh
require_pattern 'TARGET_ENVIRONMENT=k8s' scripts/deploy-federated-live.sh

require_pattern 'ENV_FEDERATED_GCE_A_URL' scripts/apply-gke-dev.sh
require_pattern 'ENV_FEDERATED_GCE_B_URL' scripts/apply-gke-dev.sh
reject_pattern 'ENV_FEDERATED_GKE_WORKER' scripts/apply-gke-dev.sh
reject_pattern 'ENV_FEDERATED_GCE_WORKER' scripts/apply-gke-dev.sh
require_pattern 'delete deployment kestra-worker --ignore-not-found' scripts/apply-gke-dev.sh
require_pattern 'delete hpa kestra-worker --ignore-not-found' scripts/apply-gke-dev.sh
reject_pattern 'rollout status deployment/kestra-worker' scripts/apply-gke-dev.sh
require_pattern 'Direct batch execution is disabled for k8s' scripts/verify-live-environments.sh
require_pattern 'Skipping k8s direct batch execution' scripts/verify-live-environments.sh
require_pattern 'controller_worker_enabled' infra/terraform/gke-dev/variables.tf
require_pattern 'google_compute_instance" "controller_worker' infra/terraform/gke-dev/main.tf
require_pattern 'server worker --thread' infra/terraform/gke-dev/controller-worker-startup.sh.tftpl

reject_pattern 'worker\.yaml' k8s/base/kustomization.yaml
if [[ -e k8s/base/worker.yaml ]]; then
  echo "Unexpected GKE worker manifest exists: k8s/base/worker.yaml" >&2
  exit 1
fi
reject_pattern 'kestra-worker' k8s/base/hpa.yaml
reject_pattern 'worker-replicas\.yaml' k8s/overlays/dev/kustomization.yaml
reject_pattern 'worker-hpa\.yaml' k8s/overlays/dev/kustomization.yaml
reject_pattern 'kestra-worker' k8s/overlays/dev/deployment-resources.yaml

require_pattern 'render-federated-child-flows\.sh" gce_a' scripts/verify-live-federated.sh
require_pattern 'render-federated-child-flows\.sh" gce_b' scripts/verify-live-federated.sh
require_pattern 'scripts/register-flows\.sh "\$\{gke_url\}" kestra/flows-federated' scripts/verify-live-federated.sh
reject_pattern 'scripts/register-flows\.sh "\$\{gke_url\}" "\$\{gce_a_flow_dir\}"' scripts/verify-live-federated.sh
reject_pattern 'scripts/register-flows\.sh "\$\{gke_url\}" "\$\{gce_b_flow_dir\}"' scripts/verify-live-federated.sh
require_pattern 'remove_gke_batch_flows' scripts/verify-live-federated.sh
require_pattern 'assert_gke_batch_flows_absent' scripts/verify-live-federated.sh
require_pattern 'assert_controller_only_task_ids' scripts/verify-live-federated.sh
require_pattern 'FEDERATED_VERIFY_RERUN="\$\{FEDERATED_VERIFY_RERUN:-true\}"' scripts/verify-live-federated.sh

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/kestra-federated-audit.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

gce_a_dir="$(scripts/render-federated-child-flows.sh gce_a kestra/flows "${tmp_dir}/server_gce_a")"
gce_b_dir="$(scripts/render-federated-child-flows.sh gce_b kestra/flows "${tmp_dir}/server_gce_b")"

ruby -ryaml -e '
  expected = ARGV.shift
  ARGV.each do |path|
    namespace = YAML.load_file(path).fetch("namespace")
    abort("#{path}: expected #{expected}, got #{namespace}") unless namespace == expected
  end
' playground.ecommerce.server_gce_a "${gce_a_dir}"/*.yaml
ruby -ryaml -e '
  expected = ARGV.shift
  ARGV.each do |path|
    namespace = YAML.load_file(path).fetch("namespace")
    abort("#{path}: expected #{expected}, got #{namespace}") unless namespace == expected
  end
' playground.ecommerce.server_gce_b "${gce_b_dir}"/*.yaml

echo "Federated topology audit passed."
