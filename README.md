# kestra-playground

Kestra deployment playground for ecommerce batch workflows. The repository keeps a small Python
package scaffold, but the primary assets are Kestra flows, local runtime scripts, Terraform, and
Kubernetes manifests.

## Requirements

- Python 3.12 or newer
- `uv`
- Nix with flakes for the full infrastructure toolchain
- Apple container for the primary local runtime, or Docker Compose as a fallback

## Quick Start

```bash
uv sync --dev
uv run python -m kestra_playground
uv run pytest
```

## Kestra Workloads

Two mock ecommerce flows live under `kestra/flows/`:

- `generate_ecommerce_mock_data` creates product, customer, order, payment, inventory, and support
  ticket data in PostgreSQL.
- `build_ecommerce_daily_report` writes and fetches daily operational metrics from that data.

Both flows use `ENV_BATCH_DB_URL`, `ENV_BATCH_DB_USERNAME`, and `ENV_BATCH_DB_PASSWORD` so local and
GCP database connection values can be switched by environment file, Secret Manager, or Kubernetes
Secret.

The generated ecommerce data is tracked in `kestra/fixtures/ecommerce/`. The generator flow embeds
those SQL fixtures into PostgreSQL tasks, and the test suite checks that the deployed flow SQL stays
in sync with the committed fixture files.

Current Kestra OSS requires Basic Auth. Local defaults are in `local/docker/.env.example`; the GCP
Terraform roots generate/store runtime credentials in Secret Manager. The GCE roots read Basic Auth
directly from Secret Manager at startup, and the GKE apply helper renders the Kubernetes Secret from
GKE-specific Secret Manager entries.

## Local Kestra

Apple container path:

```bash
cp kestra/config/envs/local.env.example kestra/config/envs/local.env
task kestra:local:apple:start
task kestra:flows:register
task kestra:flows:generate
task kestra:flows:report
task kestra:local:apple:stop
```

Docker Compose fallback:

```bash
cp local/docker/.env.example local/docker/.env
task kestra:local:docker:start
task kestra:flows:register
task kestra:flows:generate
task kestra:flows:report
task kestra:local:docker:stop
```

Kestra UI defaults to `http://localhost:8080`.

Flow helper scripts can load credentials and URL settings from an env file:

```bash
KESTRA_ENV_FILE=kestra/config/envs/local.env scripts/register-flows.sh
KESTRA_ENV_FILE=local/docker/.env scripts/register-flows.sh
```

The `task kestra:flows:*` commands use `KESTRA_ENV_FILE` when provided, otherwise they prefer
`local/docker/.env` and fall back to `kestra/config/envs/local.env`.

Registering/running flows against an authenticated endpoint:

```bash
export KESTRA_BASIC_AUTH_USERNAME=...
export KESTRA_BASIC_AUTH_PASSWORD=...
scripts/register-flows.sh http://34.84.21.87:8080
scripts/run-flow.sh generate_ecommerce_mock_data 2026-06-25 http://34.84.21.87:8080
scripts/run-flow.sh build_ecommerce_daily_report 2026-06-25 http://34.84.21.87:8080
```

## GCP Deployment Shapes

Terraform roots are split by phase:

- `infra/terraform/bootstrap-project`: creates a new GCP project and enables required APIs.
- `infra/terraform/github-actions`: creates the GitHub OIDC provider and deploy service account
  used by the push/manual/cron workflow.
- `infra/terraform/gce-single`: one GCE VM running Kestra and PostgreSQL through Docker Compose,
  with DB connection values loaded from Secret Manager.
- `infra/terraform/gce-cluster`: multiple GCE VMs running separated Kestra components against shared
  Cloud SQL and GCS.
- `infra/terraform/gke-dev`: GKE Autopilot, Cloud SQL, GCS, and Workload Identity inputs for the
  Kubernetes manifests.

The GCE cluster root runs Cloud SQL Proxy as a Docker Compose service, so Kestra uses
`cloud-sql-proxy:5432`. The GKE manifests run Cloud SQL Proxy as a sidecar in each Pod, so those
JDBC URLs use `127.0.0.1:5432`.

Example bootstrap:

```bash
cd infra/terraform/bootstrap-project
tofu init
tofu apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='billing_account=XXXXXX-XXXXXX-XXXXXX' \
  -var='org_id=123456789012'
```

The commands use OpenTofu from the Nix shell; the files are Terraform-compatible.

The live development project created for this playground is `kestra-playground-260625`.

Committed live dev tfvars live under `infra/live/dev/`. They contain non-secret environment shape
such as project, domain, subdomain, and Cloudflare zone ID. The Cloudflare API token is intentionally
kept out of git; locally it is injected from kinko:

```bash
kinko exec --env CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
task kestra:live:verify
task kestra:live:run-batch
```

Limit a command to one environment with `TARGET_ENVIRONMENT`:

```bash
TARGET_ENVIRONMENT=k8s task kestra:live:run-batch
TARGET_ENVIRONMENT=gce-container BUSINESS_DATE=2026-06-25 task kestra:live:run-batch
```

GitHub Actions deploys on push to `main`, supports manual dispatch for selected environments, and
runs the ecommerce batch on a daily cron. The workflow uses GitHub OIDC for Google Cloud auth and
expects these repository secrets:

- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT`
- `CLOUDFLARE_API_TOKEN`

The current repository secrets are initialized from the `infra/terraform/github-actions` outputs and
the kinko-managed Cloudflare token.

Live Terraform state is stored in the versioned GCS bucket
`gs://kestra-playground-260625-tofu-state`. The live roots use per-root prefixes so GitHub Actions
can deploy from a fresh checkout without recreating existing resources.

## HTTPS Domains

The GCE single-VM, GCE cluster, and GKE dev Terraform roots support HTTPS domain configuration.
The current Cloudflare-backed development hostnames are:

- GKE: `https://k8s.tacoserve.online`
- GCE clustered container environment: `https://gce-container.tacoserve.online`
- GCE single VM Docker Compose environment: `https://gce-compose.tacoserve.online`

Start from the checked-in example variables for the root you are applying:

```bash
cp infra/terraform/gce-cluster/terraform.tfvars.example infra/terraform/gce-cluster/terraform.tfvars
```

Then set `domain_name` plus an environment subdomain and apply:

```bash
tofu apply \
  -var='project_id=kestra-playground-260625' \
  -var='domain_name=tacoserve.online' \
  -var='subdomain=gce-container' \
  -var='dns_provider=cloudflare' \
  -var='cloudflare_zone_id=91eff7ce5846e9817b00bbdb9e7ef227'
```

When `dns_provider=cloudflare`, set `CLOUDFLARE_API_TOKEN` in the environment. In this workspace,
that token is stored in `kinko`, so Terraform can be run with:

```bash
kinko exec --env CLOUDFLARE_API_TOKEN -- tofu apply ...
```

When `dns_provider=google` and `create_dns_zone=true`, the root creates a Cloud DNS managed zone and outputs
`dns_name_servers`; delegate the parent domain to those name servers at the registrar. When using an
existing Cloud DNS zone, set `create_dns_zone=false` and `dns_zone_name=<zone-name>`.

After DNS record propagation, Google-managed certificates can take several minutes to become active.
The GKE root reserves the static ingress IP and creates the Cloudflare A record; the dev Kubernetes
overlay contains the matching `k8s.tacoserve.online` host and `kestra-dev-ingress` static IP name.

## Kubernetes

Kubernetes manifests are Kustomize-based:

```bash
kustomize build k8s/overlays/dev
```

Apply the live GKE overlay with Terraform outputs without writing real secrets into the repository:

```bash
task k8s:apply:dev
```

For the live GKE environment, Kestra Basic Auth is stored in Secret Manager as
`kestra-dev-gke-kestra-basic-auth-username` and
`kestra-dev-gke-kestra-basic-auth-password`. `scripts/apply-gke-dev.sh` reads those values at apply
time and writes them only into a temporary rendered manifest before updating the Kubernetes Secret.

## Common Commands

```bash
task sync
task run
task test
task lint
task typecheck
task fmt
task build
task kestra:local:apple:start
task kestra:flows:register
task infra:fmt
task k8s:build:dev
task k8s:apply:dev
```
