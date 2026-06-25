# Command Design

This document describes CLI command interface design specifications.

## Overview

Command-line interface design decisions, including subcommands, flags, options, and environment variables.

---

## Sections

### Subcommands

Define the CLI subcommand structure and hierarchy.

### Flags and Options

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| (Add flags here) | | | |

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| (Add env vars here) | | | |

## Kestra Playground Commands

### Local Apple Container

```bash
local/apple-container/start.sh
scripts/register-flows.sh http://localhost:8080
scripts/run-flow.sh generate_ecommerce_mock_data
scripts/run-flow.sh build_ecommerce_daily_report
scripts/run-flow.sh build_ecommerce_customer_segments
local/apple-container/stop.sh
```

### Local Docker Compose Fallback

```bash
docker compose --env-file local/docker/.env.example -f local/docker/docker-compose.yml up -d
scripts/register-flows.sh http://localhost:8080
scripts/run-flow.sh generate_ecommerce_mock_data
scripts/run-flow.sh build_ecommerce_daily_report
scripts/run-flow.sh build_ecommerce_customer_segments
docker compose -f local/docker/docker-compose.yml down
```

Flow execution defaults to the current date in `Asia/Tokyo` when no business date is provided. Set
`BUSINESS_DATE=YYYY-MM-DD` or pass the second `scripts/run-flow.sh` argument to run a specific
partition. `scripts/run-flow.sh` also honors `BUSINESS_DATE` and `BUSINESS_DATE_TZ` from
`KESTRA_ENV_FILE`; explicit dates must use `YYYY-MM-DD`.

### Terraform Project Bootstrap

```bash
cd infra/terraform/bootstrap-project
tofu init
tofu apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='billing_account=XXXXXX-XXXXXX-XXXXXX' \
  -var='org_id=123456789012'
```

### Terraform GCE Single VM

```bash
cd infra/terraform/gce-single
tofu init
tofu apply -var='project_id=kestra-playground-dev-<unique-suffix>'
```

With HTTPS domain resources:

```bash
tofu apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='domain_name=example.com' \
  -var='subdomain=dev'
```

### Terraform GCE Cluster

```bash
cd infra/terraform/gce-cluster
tofu init
tofu apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='cluster_size=2'
```

With HTTPS domain resources:

```bash
tofu apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='cluster_size=2' \
  -var='domain_name=example.com' \
  -var='subdomain=cluster-dev'
```

### Terraform GKE Dev

```bash
cd infra/terraform/gke-dev
tofu init
tofu apply -var='project_id=kestra-playground-dev-<unique-suffix>'
gcloud container clusters get-credentials kestra-dev --region asia-northeast1
scripts/apply-gke-dev.sh
```

For GKE HTTPS, pass `domain_name`, `subdomain`, and the DNS provider inputs, then run
`scripts/apply-gke-dev.sh`. The helper reads Terraform outputs, renders sensitive values into a
temporary manifest only, and waits for Kestra deployments to roll out.

### Live Operations

```bash
kinko exec --env CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
task kestra:live:verify
task kestra:live:run-batch
TARGET_ENVIRONMENT=k8s BUSINESS_DATE=2026-06-25 task kestra:live:run-batch
```

## Kestra GCP Operations Runbook

Use this runbook when building, releasing, deploying, or verifying the live development Kestra
playground. The current live project is `example-project-id` in `asia-northeast1`.

### Environment Map

| Target | Alias | Public URL | Terraform root | Runtime shape |
|--------|-------|------------|----------------|---------------|
| `gce-compose` | `gce-single` | `https://gce-compose.example.com` | `infra/terraform/gce-single` | Single GCE VM running Docker Compose |
| `gce-container` | `gce-cluster` | `https://gce-container.example.com` | `infra/terraform/gce-cluster` | GCE managed instance group running split Kestra components |
| `k8s` | `gke-dev` | `https://k8s.example.com` | `infra/terraform/gke-dev` | GKE Autopilot with Kustomize manifests |

The runtime image repository is:

```text
asia-northeast1-docker.pkg.dev/example-project-id/kestra-playground/kestra-runtime
```

### Prerequisites

Run commands through the Nix development shell so `python`, `gcloud`, `tofu`, `kubectl`,
`kustomize`, `task`, `docker`, `jq`, and `shellcheck` are available:

```bash
nix develop
```

Authenticate to Google Cloud before live operations:

```bash
gcloud auth login
gcloud config set project example-project-id
gcloud auth application-default login
```

Cloudflare DNS changes require `CLOUDFLARE_API_TOKEN`. Load it from `kinko`; do not write the token
to repository files:

```bash
kinko exec --env CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
```

### Local Development Check

Start the local runtime, register flows, and run the three batch flows:

```bash
task kestra:local:docker:start
task kestra:flows:register
task kestra:flows:generate
task kestra:flows:report
task kestra:flows:segments
```

To run a fixed partition, pass `BUSINESS_DATE`:

```bash
BUSINESS_DATE=2026-06-25 task kestra:flows:segments
```

Stop local Docker services when finished:

```bash
task kestra:local:docker:stop
```

### Release Path

The normal release path is a push to `main`. GitHub Actions validates the repo, builds the runtime
container, pushes two Artifact Registry tags, then deploys the SHA-tagged image:

```text
<repository>:<git-sha>
<repository>:latest
```

The deploy job passes the SHA-tagged image as `KESTRA_IMAGE` to `scripts/deploy-live-environments.sh`.
For a manual local redeploy of an existing image, set `KESTRA_IMAGE` explicitly:

```bash
export KESTRA_IMAGE="asia-northeast1-docker.pkg.dev/example-project-id/kestra-playground/kestra-runtime:<git-sha>"
kinko exec --env CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
```

### Deploy Targets

Deploy all environments:

```bash
kinko exec --env CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
```

Deploy one environment:

```bash
TARGET_ENVIRONMENT=gce-compose kinko exec --env CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
TARGET_ENVIRONMENT=gce-container kinko exec --env CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
TARGET_ENVIRONMENT=k8s kinko exec --env CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
```

The GKE deploy path also refreshes local kubeconfig and applies the rendered Kustomize overlay:

```bash
gcloud container clusters get-credentials kestra-dev --region asia-northeast1 --project example-project-id
scripts/apply-gke-dev.sh
```

### Health Verification

Run health verification after every deploy. This waits for each HTTPS UI endpoint and registers the
checked-in flows without executing batch work:

```bash
task kestra:live:verify
TARGET_ENVIRONMENT=k8s task kestra:live:verify
```

### Batch Verification

Run all batch flows in dependency order:

```bash
task kestra:live:run-batch
```

For repeatable verification, pin the business date:

```bash
BUSINESS_DATE=2026-06-25 task kestra:live:run-batch
TARGET_ENVIRONMENT=gce-container BUSINESS_DATE=2026-06-25 task kestra:live:run-batch
```

If `BUSINESS_DATE` is unset or blank, the helper uses the current `Asia/Tokyo` date. Set
`BUSINESS_DATE_TZ` to use a different default timezone. Invalid date strings fail before any flow is
started.

The live verification helper loads Kestra Basic Auth credentials from Secret Manager and runs:

1. `generate_ecommerce_mock_data`
2. `build_ecommerce_daily_report`
3. `build_ecommerce_customer_segments`

### UI Verification

When visible browser verification is required, use Computer Use with Brave Browser and visit the
public URL for each target. Confirm that login succeeds, open
`playground.ecommerce/build_ecommerce_customer_segments`, and check that recent executions show
`SUCCESS`.

Do not print live Basic Auth secret values. Retrieve them from Secret Manager only into process
environment variables, clipboard, or a non-committed local shell.

### Secret Checks

Verify Secret Manager versions are enabled without printing secret payloads:

```bash
for secret in \
  kestra-dev-kestra-basic-auth-username \
  kestra-dev-kestra-basic-auth-password \
  kestra-cluster-dev-kestra-basic-auth-username \
  kestra-cluster-dev-kestra-basic-auth-password \
  kestra-dev-gke-kestra-basic-auth-username \
  kestra-dev-gke-kestra-basic-auth-password; do
  gcloud secrets versions list "$secret" \
    --project=example-project-id \
    --filter='state:ENABLED' \
    --limit=1 \
    --format='value(name,state)'
done
```

For GKE, confirm the rendered Kubernetes Secret contains both helper and canonical Kestra Basic Auth
keys:

```bash
kubectl -n kestra-dev get secret kestra-secrets -o json | jq -r '.data | keys[]' | sort
```

Expected key families include:

- `ENV_BATCH_DB_*`
- `KESTRA_DB_*`
- `KESTRA_BASIC_AUTH_*`
- `KESTRA_SERVER_BASIC__AUTH_*`
- `KESTRA_GCS_BUCKET`

### Image And Rollout Checks

Check the latest Artifact Registry image:

```bash
gcloud artifacts docker images list \
  asia-northeast1-docker.pkg.dev/example-project-id/kestra-playground/kestra-runtime \
  --include-tags \
  --sort-by='~UPDATE_TIME' \
  --limit=5
```

Check GKE deployment images and readiness:

```bash
kubectl -n kestra-dev get deployments
kubectl -n kestra-dev get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

Check GCE instance health:

```bash
gcloud compute instance-groups unmanaged list-instances kestra-dev-single \
  --zone=asia-northeast1-a \
  --project=example-project-id

gcloud compute instance-groups managed describe kestra-cluster-dev-mig \
  --region=asia-northeast1 \
  --project=example-project-id \
  --format=json | jq '.targetSize,.currentActions'
```

### Drift Checks

Before changing live infrastructure, run targeted plans with the committed live tfvars:

```bash
kinko exec --env CLOUDFLARE_API_TOKEN -- \
  tofu -chdir=infra/terraform/gce-single plan -var-file=../../live/dev/gce-single.tfvars
kinko exec --env CLOUDFLARE_API_TOKEN -- \
  tofu -chdir=infra/terraform/gce-cluster plan -var-file=../../live/dev/gce-cluster.tfvars
kinko exec --env CLOUDFLARE_API_TOKEN -- \
  tofu -chdir=infra/terraform/gke-dev plan -var-file=../../live/dev/gke-dev.tfvars
```

### Troubleshooting

Use these checks before changing infrastructure:

```bash
curl -I https://gce-compose.example.com/ui/
curl -I https://gce-container.example.com/ui/
curl -I https://k8s.example.com/ui/
```

For failed Kestra executions, inspect the execution in the UI first, then query by execution ID with
Basic Auth if needed. For failed GKE rollouts, prefer `kubectl -n kestra-dev describe deployment`,
`kubectl -n kestra-dev describe pod`, and container logs before reapplying Terraform.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| (Add more exit codes as needed) | |

---
