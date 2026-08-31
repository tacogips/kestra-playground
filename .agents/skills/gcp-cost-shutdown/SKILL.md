---
name: gcp-cost-shutdown
description: Shut down every cost-bearing GCE and GCP runtime in the Kestra playground project, audit what is currently running, or investigate unexpected GCP spend. Use when asked to stop, halt, scale to zero, or reduce the cost of GCE VMs, managed instance groups, GKE clusters, Cloud SQL, or Cloud Run, when asked how much the project is costing, or when checking whether anything was left running after an experiment.
---

# GCP Cost Shutdown

## Overview

This project repeatedly left GCE and GKE resources running unattended. Use this skill to stop
everything safely, to confirm nothing is still burning money, and to investigate what ran and when.

The default action is a **reversible stop**. Never delete unless the user explicitly asks for
deletion after being told what is lost.

## Non-Negotiable Rules

1. **Stop, do not delete.** Deletion is a separate decision that only the user makes.
2. **Confirm the project ID before acting.** The live project is `kestra-playground-260625`. The
   `gcloud` default is often a different project (`ai-tools-proj`) and running a shutdown against
   the wrong project is unrecoverable. Always pass `--project` explicitly; never rely on
   `gcloud config`.
3. **Dry run first.** Show the user what will stop, then execute.
4. **Never run the `emergency-shutdown` job unless the user explicitly asks for deletion.** See
   Known Hazard below.
5. **Never invent cost figures.** If billing data is unavailable, say so and link the Console.

## Known Hazard: the emergency-shutdown job

`.github/workflows/deploy.yml` contains a `emergency-shutdown` job that is **not** a stop. It runs
`gcloud projects delete`, then deletes Cloud SQL instances, recursively wipes every GCS bucket, and
deletes Artifact Registry repositories.

On 2026-08-31 this job was run. It destroyed the GCS bucket holding the OpenTofu/Terraform remote
state for every root in `infra/terraform/` (each `backend.tf` points at GCS). The local
`terraform.tfstate` files are 0 bytes; only the 2026-06-25 `.backup` snapshots survive. Any rebuild
now starts from incomplete state.

Do not offer this job as a way to "stop" resources. If the user wants cost to reach zero, explain
that stopping leaves storage costs and let them choose deletion explicitly.

## Procedure

### 1. Verify access and target

```bash
gcloud projects describe kestra-playground-260625 --format='value(projectId,lifecycleState)'
```

If this fails with a reauth error, `gcloud auth login` is required. It is interactive and cannot be
run non-interactively -- ask the user to run it. Do not retry the failing command repeatedly.

### 2. Inventory what is running

```bash
P=kestra-playground-260625
gcloud compute instances list --project=$P --format='table(name,zone,machineType.basename(),status)'
gcloud compute instance-groups managed list --project=$P --format='table(name,zone,region,targetSize)'
gcloud container clusters list --project=$P --format='table(name,location,currentNodeCount,status)'
gcloud sql instances list --project=$P --format='table(name,tier,state,settings.activationPolicy)'
gcloud run services list --platform=managed --project=$P
```

Report the inventory before changing anything.

### 3. Stop

```bash
PROJECT_ID=kestra-playground-260625 scripts/gcp-stop-all.sh            # dry run
PROJECT_ID=kestra-playground-260625 DRY_RUN=0 scripts/gcp-stop-all.sh  # execute
```

The script resizes MIGs to 0, scales GKE node pools to 0, stops running VMs, sets Cloud SQL
`activation-policy=NEVER`, and sets Cloud Run `min-instances=0`. It then verifies and prints the
residual-cost inventory.

### 4. Report residual cost honestly

Stopping does **not** reach zero. These keep billing:

| Resource | Why |
|----------|-----|
| Persistent disks | Charged at full rate while the instance is stopped |
| GCS buckets | Storage billed regardless of activity |
| Static IPs | Reserved-but-idle IPs cost more than attached ones |
| Artifact Registry | Image storage billed per GB |
| Cloud SQL backups | Retained backups billed after the instance stops |

Always list these with sizes so the user can decide about deletion separately.

## Cost Investigation

There is **no BigQuery billing export** configured for this billing account, so `gcloud` and `bq`
cannot produce a daily cost breakdown. Do not fabricate one from list prices.

The billing account ID is a live config value and is deliberately not committed (see commit
`9075975`, "move live config values out of git"). Resolve it at runtime:

```bash
BILLING_ID=$(gcloud billing projects describe "$P" \
  --format='value(billingAccountName)' | sed 's#billingAccounts/##')
echo "https://console.cloud.google.com/billing/${BILLING_ID}/reports?project=${P}"
```

Do not paste the resulting billing account ID into any committed file; this repository is public.

Recommend enabling BigQuery billing export so this gap closes permanently.

### Audit-log forensics

Admin Activity logs reach back to project creation (2026-06-25) and are the reliable way to
reconstruct what ran. Bound queries by time and resource name; broad `NOT` filters time out.

Creation events per day:

```bash
gcloud logging read \
  'protoPayload.methodName="v1.compute.instances.insert" AND timestamp>="2026-08-01T00:00:00Z"' \
  --project=$P --limit=5000 --format='value(timestamp)' | cut -c1-10 | sort | uniq -c
```

If the result count equals `--limit`, the window is truncated -- narrow the time range and re-run.
Each instance creation emits roughly two log entries, so halve raw counts.

Was a specific VM ever powered off?

```bash
gcloud logging read \
  'protoPayload.methodName=("v1.compute.instances.stop" OR "v1.compute.instances.start")
   AND protoPayload.resourceName:"kestra-dev-gce"' \
  --project=$P --limit=200 --order=asc \
  --format='value(timestamp,protoPayload.methodName,protoPayload.resourceName)'
```

Absence of `stop` events between creation and deletion means the VM ran continuously and was billed
for that entire span.

## Cost History

Recorded so recurrence is recognizable:

- **2026-06-25**: project created; `gce-single`, `gce-cluster`, and `gke-dev` stacks all deployed in
  parallel, each with its own static IP, and `gce-cluster` plus `gke-dev` each with their own
  `db-g1-small` Cloud SQL instance (duplicate databases for one workload).
- **2026-06-26 to 2026-08-31**: `kestra-dev-gce-a` and `kestra-dev-gce-b` ran continuously for 66
  days. Only two brief stop/start pairs exist (2026-07-17, 2026-08-26).
- **2026-07-17**: scale-to-zero added, but only to `infra/terraform/gke-dev/`. The GCE stacks never
  got it and kept running.
- **2026-08-06 to 2026-08-13**: GKE Autopilot node churn peaked near 1000 node creations per day.
- **2026-08-31**: `emergency-shutdown` run; all compute, Cloud SQL, and GCS buckets deleted.

Recurrence signature: a stack gets superseded by a newer one but is never destroyed, stays wired
into `scripts/deploy-live-environments.sh`, and keeps billing silently.

## Prevention Checklist

When adding or replacing a GCP stack, confirm all of these:

- [ ] The superseded stack is destroyed, not just abandoned.
- [ ] `scripts/deploy-live-environments.sh` and `.agents/skills/kestra-gcp-operations/SKILL.md` no
      longer reference the retired stack.
- [ ] The new stack has a scale-to-zero or scheduled-stop path.
- [ ] No duplicate Cloud SQL instance was created for an existing database.
- [ ] A budget alert exists on the billing account linked to the project.
- [ ] BigQuery billing export is enabled.

## Documentation

When shutdown behavior changes, update `design-docs/specs/command.md` and record observed cost
incidents in `design-docs/specs/notes.md`.
