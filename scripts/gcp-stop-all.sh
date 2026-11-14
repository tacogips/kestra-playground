#!/usr/bin/env bash
# Reversible shutdown of every cost-bearing runtime in the Kestra playground project.
#
# This script STOPS. It never deletes. Data (disks, Cloud SQL contents, GCS
# objects, Artifact Registry images, Secret Manager values) is preserved so the
# environment can be restarted with scripts/deploy-live-environments.sh.
#
# For the deletion path see the `emergency-shutdown` job in
# .github/workflows/deploy.yml -- that one is irreversible and destroys the
# Terraform state bucket. Prefer this script.
#
# Usage:
#   PROJECT_ID=kestra-playground-260625 scripts/gcp-stop-all.sh            # dry run
#   PROJECT_ID=kestra-playground-260625 DRY_RUN=0 scripts/gcp-stop-all.sh  # execute
set -uo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
DRY_RUN="${DRY_RUN:-1}"

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

if ! gcloud projects describe "${PROJECT_ID}" --format='value(projectId)' >/dev/null 2>&1; then
  echo "Cannot reach project ${PROJECT_ID}. Run 'gcloud auth login' first." >&2
  exit 1
fi

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  [dry-run] $*"
  else
    echo "  [exec] $*"
    "$@" || echo "  !! failed (continuing): $*" >&2
  fi
}

echo "=== project ${PROJECT_ID} (DRY_RUN=${DRY_RUN}) ==="

echo "--- managed instance groups -> size 0 ---"
gcloud compute instance-groups managed list --project="${PROJECT_ID}" \
  --format='csv[no-heading](name,zone,region)' 2>/dev/null |
while IFS=, read -r name zone region; do
  [[ -n "${name}" ]] || continue
  if [[ -n "${zone}" ]]; then
    run gcloud compute instance-groups managed resize "${name}" --size=0 \
      --zone="${zone##*/}" --project="${PROJECT_ID}" --quiet
  else
    run gcloud compute instance-groups managed resize "${name}" --size=0 \
      --region="${region##*/}" --project="${PROJECT_ID}" --quiet
  fi
done

echo "--- GKE node pools -> 0 nodes ---"
gcloud container clusters list --project="${PROJECT_ID}" \
  --format='csv[no-heading](name,location,autopilot.enabled)' 2>/dev/null |
while IFS=, read -r cluster location autopilot; do
  [[ -n "${cluster}" ]] || continue
  if [[ "${autopilot}" == "True" ]]; then
    echo "  !! ${cluster} is Autopilot: node count is not user-controlled."
    echo "     Scale workloads instead: kubectl scale --replicas=0, or suspend CronJobs."
    continue
  fi
  gcloud container node-pools list --cluster="${cluster}" --location="${location}" \
    --project="${PROJECT_ID}" --format='value(name)' 2>/dev/null |
  while read -r pool; do
    [[ -n "${pool}" ]] || continue
    run gcloud container clusters resize "${cluster}" --node-pool="${pool}" --num-nodes=0 \
      --location="${location}" --project="${PROJECT_ID}" --quiet
  done
done

echo "--- running instances -> stop (disks preserved) ---"
gcloud compute instances list --project="${PROJECT_ID}" --filter='status=RUNNING' \
  --format='csv[no-heading](name,zone)' 2>/dev/null |
while IFS=, read -r name zone; do
  [[ -n "${name}" ]] || continue
  run gcloud compute instances stop "${name}" --zone="${zone##*/}" \
    --project="${PROJECT_ID}" --quiet
done

echo "--- Cloud SQL -> activation-policy NEVER (data preserved) ---"
gcloud sql instances list --project="${PROJECT_ID}" --format='value(name)' 2>/dev/null |
while read -r name; do
  [[ -n "${name}" ]] || continue
  run gcloud sql instances patch "${name}" --activation-policy=NEVER \
    --project="${PROJECT_ID}" --quiet
done

echo "--- Cloud Run -> min-instances 0 (scale to zero when idle) ---"
gcloud run services list --platform=managed --project="${PROJECT_ID}" \
  --format='csv[no-heading](metadata.name,region)' 2>/dev/null |
while IFS=, read -r name region; do
  [[ -n "${name}" ]] || continue
  run gcloud run services update "${name}" --min-instances=0 \
    --region="${region:-${REGION}}" --project="${PROJECT_ID}" --quiet
done

echo
echo "=== VERIFY (expect 0 for the first four) ==="
printf '  running instances : %s\n' "$(gcloud compute instances list --project="${PROJECT_ID}" --filter='status=RUNNING' --format='value(name)' 2>/dev/null | grep -c . || true)"
printf '  MIGs with size>0  : %s\n' "$(gcloud compute instance-groups managed list --project="${PROJECT_ID}" --filter='targetSize>0' --format='value(name)' 2>/dev/null | grep -c . || true)"
printf '  GKE clusters      : %s\n' "$(gcloud container clusters list --project="${PROJECT_ID}" --format='value(name)' 2>/dev/null | grep -c . || true)"
printf '  SQL not-stopped   : %s\n' "$(gcloud sql instances list --project="${PROJECT_ID}" --filter='settings.activationPolicy!=NEVER' --format='value(name)' 2>/dev/null | grep -c . || true)"

echo
echo "=== RESIDUAL COST (still billed after stop; nothing deleted) ==="
echo "-- persistent disks (billed while instances are stopped):"
gcloud compute disks list --project="${PROJECT_ID}" --format='table(name,zone.basename(),sizeGb,type.basename())' 2>/dev/null
echo "-- static IPs (idle reserved IPs cost more than attached ones):"
gcloud compute addresses list --project="${PROJECT_ID}" --format='table(name,region.basename(),status)' 2>/dev/null
echo "-- GCS buckets:"
gcloud storage buckets list --project="${PROJECT_ID}" --format='value(name)' 2>/dev/null
echo "-- Artifact Registry:"
gcloud artifacts repositories list --project="${PROJECT_ID}" --format='table(name,format,sizeBytes)' 2>/dev/null
echo "-- Cloud SQL backups:"
gcloud sql instances list --project="${PROJECT_ID}" --format='value(name)' 2>/dev/null |
while read -r name; do
  [[ -n "${name}" ]] || continue
  gcloud sql backups list --instance="${name}" --project="${PROJECT_ID}" --format='value(id,windowStartTime)' 2>/dev/null | head -5
done

echo
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "Dry run only. Re-run with DRY_RUN=0 to apply."
fi
