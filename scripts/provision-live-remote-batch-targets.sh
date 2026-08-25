#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-up}"
PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
ZONE="${ZONE:-asia-northeast1-a}"
NETWORK="${REMOTE_BATCH_NETWORK:-kestra-remote-batch}"
SUBNET="${REMOTE_BATCH_SUBNET:-kestra-remote-batch}"
FIREWALL="${REMOTE_BATCH_FIREWALL:-kestra-remote-batch-ssh}"
INSTANCE_A="${REMOTE_BATCH_INSTANCE_A:-kestra-remote-batch-a}"
INSTANCE_B="${REMOTE_BATCH_INSTANCE_B:-kestra-remote-batch-b}"
ADDRESS_A="${REMOTE_BATCH_ADDRESS_A:-kestra-remote-batch-a}"
ADDRESS_B="${REMOTE_BATCH_ADDRESS_B:-kestra-remote-batch-b}"
MACHINE_TYPE="${REMOTE_BATCH_MACHINE_TYPE:-e2-micro}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STARTUP_SCRIPT="${ROOT_DIR}/scripts/live-remote-batch-target-startup.sh"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "PROJECT_ID or GCP_PROJECT_ID is required." >&2
  exit 1
fi

if [[ -z "${REMOTE_BATCH_SSH_SOURCE_CIDR:-}" ]]; then
  source_ip="$(curl --fail --silent --show-error https://api.ipify.org)"
  if [[ ! "${source_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Unable to resolve a valid IPv4 source address for the SSH firewall." >&2
    exit 1
  fi
  REMOTE_BATCH_SSH_SOURCE_CIDR="${source_ip}/32"
fi

gcloud_args=(--project="${PROJECT_ID}" --quiet)

# Registry mode: when PYTHON_REGISTRY_INDEX_URL is set, the startup script
# installs kestra-batch-common from the private Artifact Registry repository.
# KESTRA_BATCH_COMMON_SPEC optionally pins the version (e.g. kestra-batch-common==0.1.0).
INSTANCE_METADATA="remote-batch-sshd-disabled=false"
if [[ -n "${PYTHON_REGISTRY_INDEX_URL:-}" ]]; then
  INSTANCE_METADATA+=",python-registry-index-url=${PYTHON_REGISTRY_INDEX_URL}"
fi
if [[ -n "${KESTRA_BATCH_COMMON_SPEC:-}" ]]; then
  INSTANCE_METADATA+=",kestra-batch-common-spec=${KESTRA_BATCH_COMMON_SPEC}"
fi

resource_exists() {
  "$@" >/dev/null 2>&1
}

ensure_network() {
  if ! resource_exists gcloud compute networks describe "${NETWORK}" "${gcloud_args[@]}"; then
    gcloud compute networks create "${NETWORK}" \
      --subnet-mode=custom \
      "${gcloud_args[@]}"
  fi

  if ! resource_exists gcloud compute networks subnets describe "${SUBNET}" \
    --region="${REGION}" "${gcloud_args[@]}"; then
    gcloud compute networks subnets create "${SUBNET}" \
      --network="${NETWORK}" \
      --region="${REGION}" \
      --range=10.42.0.0/24 \
      "${gcloud_args[@]}"
  fi

  if resource_exists gcloud compute firewall-rules describe "${FIREWALL}" "${gcloud_args[@]}"; then
    gcloud compute firewall-rules update "${FIREWALL}" \
      --source-ranges="${REMOTE_BATCH_SSH_SOURCE_CIDR}" \
      "${gcloud_args[@]}"
  else
    gcloud compute firewall-rules create "${FIREWALL}" \
      --network="${NETWORK}" \
      --allow=tcp:22 \
      --source-ranges="${REMOTE_BATCH_SSH_SOURCE_CIDR}" \
      --target-tags=kestra-remote-batch-target \
      "${gcloud_args[@]}"
  fi
}

ensure_address() {
  local address_name="$1"

  if ! resource_exists gcloud compute addresses describe "${address_name}" \
    --region="${REGION}" "${gcloud_args[@]}"; then
    gcloud compute addresses create "${address_name}" \
      --region="${REGION}" \
      "${gcloud_args[@]}"
  fi
}

ensure_instance() {
  local instance_name="$1"
  local address_name="$2"
  local address
  local status

  address="$(
    gcloud compute addresses describe "${address_name}" \
      --region="${REGION}" \
      --format='value(address)' \
      "${gcloud_args[@]}"
  )"

  if ! resource_exists gcloud compute instances describe "${instance_name}" \
    --zone="${ZONE}" "${gcloud_args[@]}"; then
    gcloud compute instances create "${instance_name}" \
      --zone="${ZONE}" \
      --machine-type="${MACHINE_TYPE}" \
      --subnet="${SUBNET}" \
      --address="${address}" \
      --image-family=debian-12 \
      --image-project=debian-cloud \
      --boot-disk-size=10GB \
      --boot-disk-type=pd-standard \
      --tags=kestra-remote-batch-target \
      --scopes=cloud-platform \
      --metadata="${INSTANCE_METADATA}" \
      --metadata-from-file=startup-script="${STARTUP_SCRIPT}" \
      "${gcloud_args[@]}"
    return
  fi

  status="$(
    gcloud compute instances describe "${instance_name}" \
      --zone="${ZONE}" \
      --format='value(status)' \
      "${gcloud_args[@]}"
  )"
  if [[ "${status}" != "RUNNING" ]]; then
    gcloud compute instances start "${instance_name}" --zone="${ZONE}" "${gcloud_args[@]}"
  fi
  gcloud compute instances add-metadata "${instance_name}" \
    --zone="${ZONE}" \
    --metadata="${INSTANCE_METADATA}" \
    "${gcloud_args[@]}"
}

wait_for_startup() {
  local instance_name="$1"

  for _ in {1..60}; do
    if gcloud compute ssh "${instance_name}" \
      --zone="${ZONE}" \
      --command='test -f /var/lib/kestra-remote-batch-ready' \
      --ssh-flag='-o ConnectTimeout=5' \
      "${gcloud_args[@]}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  echo "Startup did not complete on ${instance_name}." >&2
  return 1
}

set_batch_password() {
  local instance_name="$1"

  if [[ -z "${REMOTE_BATCH_PASSWORD:-}" ]]; then
    echo "REMOTE_BATCH_PASSWORD is required to configure the batch account." >&2
    return 1
  fi

  printf 'batch:%s\n' "${REMOTE_BATCH_PASSWORD}" \
    | gcloud compute ssh "${instance_name}" \
      --zone="${ZONE}" \
      --command='sudo chpasswd' \
      "${gcloud_args[@]}" >/dev/null
}

print_status() {
  gcloud compute instances list \
    --filter="name=(${INSTANCE_A} ${INSTANCE_B})" \
    --format='table(name,zone.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)' \
    "${gcloud_args[@]}"
}

case "${ACTION}" in
  up)
    ensure_network
    ensure_address "${ADDRESS_A}"
    ensure_address "${ADDRESS_B}"
    ensure_instance "${INSTANCE_A}" "${ADDRESS_A}"
    ensure_instance "${INSTANCE_B}" "${ADDRESS_B}"
    wait_for_startup "${INSTANCE_A}"
    wait_for_startup "${INSTANCE_B}"
    set_batch_password "${INSTANCE_A}"
    set_batch_password "${INSTANCE_B}"
    print_status
    ;;
  start)
    ensure_instance "${INSTANCE_A}" "${ADDRESS_A}"
    ensure_instance "${INSTANCE_B}" "${ADDRESS_B}"
    wait_for_startup "${INSTANCE_A}"
    wait_for_startup "${INSTANCE_B}"
    set_batch_password "${INSTANCE_A}"
    set_batch_password "${INSTANCE_B}"
    print_status
    ;;
  status)
    print_status
    ;;
  stop)
    gcloud compute instances stop "${INSTANCE_A}" "${INSTANCE_B}" \
      --zone="${ZONE}" \
      "${gcloud_args[@]}"
    print_status
    ;;
  *)
    echo "usage: $0 {up|start|status|stop}" >&2
    exit 2
    ;;
esac
