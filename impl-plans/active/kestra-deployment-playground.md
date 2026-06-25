# Kestra Deployment Playground Plan

**Status**: IN_PROGRESS  
**Design Reference**: `design-docs/specs/architecture.md`  
**Created**: 2026-06-25  
**Updated**: 2026-06-25

## Scope

Build a Kestra playground that can run ecommerce mock batch workflows locally and across GCP
deployment shapes: single GCE VM, clustered GCE VMs, and GKE with environment-specific Kubernetes
overlays. The project must include the execution plan, local runtime assets, Terraform, Kubernetes
manifests, and development-shell dependencies.

## Workstreams

### 1. Local Runtime And Flows

**Deliverables**:
- `kestra/flows/generate_ecommerce_mock_data.yaml`
- `kestra/flows/build_ecommerce_daily_report.yaml`
- `kestra/config/application.yaml`
- `kestra/config/envs/local.env.example`
- `local/apple-container/start.sh`
- `local/apple-container/stop.sh`
- `local/docker/docker-compose.yml`

**Status**: COMPLETED

**Validation**:
- Flow YAML parses.
- Local scripts reference Apple container commands and mounted Kestra config.
- Docker Compose fallback uses the same config and flow environment contract.
- Flow helper scripts can load Kestra URL/auth values from `KESTRA_ENV_FILE`.

**Checklist**:
- [x] Create ecommerce data generator flow.
- [x] Create ecommerce report flow.
- [x] Add local Kestra config and env file.
- [x] Add Apple container start/stop scripts.
- [x] Add Docker Compose fallback.

### 2. GCP Single VM Terraform

**Deliverables**:
- `infra/terraform/bootstrap-project/`
- `infra/terraform/gce-single/`

**Status**: COMPLETED

**Validation**:
- Terraform formats cleanly.
- Bootstrap root creates a new GCP project and enables required APIs.
- Single root creates Secret Manager secrets, GCE, firewall, and a startup script for Docker Compose
  with Kestra and PostgreSQL services.
- Optional HTTPS resources create Cloud DNS, a static global IP, Google-managed SSL certificate, and
  HTTPS load balancer for an environment subdomain.

**Checklist**:
- [x] Add project bootstrap root.
- [x] Add single-VM root.
- [x] Store DB connection values in Secret Manager.
- [x] Generate VM startup compose script.

### 3. GCE Cluster Terraform

**Deliverables**:
- `infra/terraform/gce-cluster/`

**Status**: COMPLETED

**Validation**:
- Terraform formats cleanly.
- Cluster root creates multiple GCE instances, shared Cloud SQL/GCS backends, and a webserver load
  balancer.
- Startup script runs separated Kestra components.
- Optional HTTPS resources create Cloud DNS, a static global IP, Google-managed SSL certificate, and
  HTTPS load balancer for an environment subdomain.

**Checklist**:
- [x] Add shared managed services.
- [x] Add service account and IAM.
- [x] Add regional instance group.
- [x] Add load balancer and health check.

### 4. GKE Dev Manifests

**Deliverables**:
- `infra/terraform/gke-dev/`
- `k8s/base/`
- `k8s/overlays/dev/`

**Status**: COMPLETED

**Validation**:
- Kustomize build succeeds.
- Base/overlay split allows environment overrides.
- Dev overlay configures Workload Identity and autoscaling.
- Terraform can reserve the GKE Ingress static IP and DNS record; the dev overlay includes
  GKE-managed certificate and Ingress placeholders.
- GKE Ingress uses a NEG-backed `ClusterIP` Service and a BackendConfig health check on `/ui/`.

**Checklist**:
- [x] Add GKE Autopilot Terraform root.
- [x] Add Kustomize base manifests.
- [x] Add dev overlay patches.
- [x] Include Cloud SQL Auth Proxy sidecars.

### 5. Tooling And Documentation

**Deliverables**:
- `flake.nix`
- `README.md`
- `Taskfile.yml`
- `scripts/register-flows.sh`
- `scripts/run-flow.sh`

**Status**: COMPLETED

**Validation**:
- Dev shell includes Terraform/OpenTofu, gcloud, kubectl, helm, kustomize, PostgreSQL client, jq,
  yq, Docker Compose-compatible tooling, and shellcheck.
- README documents local and GCP paths.
- Script shell syntax checks pass where tools are available.

**Checklist**:
- [x] Add required dependencies to `flake.nix`.
- [x] Add repeatable Taskfile commands.
- [x] Document setup and execution.
- [x] Run available static checks.

## Status Table

| Workstream | Deliverables | Status | Validation |
|------------|--------------|--------|------------|
| Local Runtime And Flows | `kestra/`, `local/` | COMPLETED | YAML, ShellCheck, Compose render |
| GCP Single VM Terraform | `infra/terraform/bootstrap-project`, `infra/terraform/gce-single` | COMPLETED | `tofu validate` |
| GCE Cluster Terraform | `infra/terraform/gce-cluster` | COMPLETED | `tofu validate` |
| GKE Dev Manifests | `infra/terraform/gke-dev`, `k8s/` | COMPLETED | `tofu validate`, Kustomize render |
| Tooling And Documentation | `flake.nix`, `README.md`, `Taskfile.yml`, `scripts/` | COMPLETED | Nix shell, Python checks |

## Dependencies

- GCP organization or folder ID and billing account are required to apply project bootstrap.
- GCP credentials must have project creation, billing attachment, IAM, Compute, Cloud SQL, GKE,
  Secret Manager, and Storage permissions. Cloud SQL is used by the cluster and GKE roots; the
  single-VM root uses PostgreSQL in Docker Compose.
- A real parent DNS domain is required before live HTTPS certificate provisioning can be verified.
- Apple container local path requires Apple Silicon macOS with the `container` CLI installed and
  system services started.
- Live Terraform apply, GKE deploy, and Kestra runtime verification require cloud credentials and
  local container runtime access.

## Completion Criteria

- [x] Two ecommerce mock Kestra flows exist and can be registered.
- [x] Local Apple container scripts and Docker Compose fallback can run Kestra with PostgreSQL.
- [x] Terraform can create a new GCP project and all requested GCP deployment shapes.
- [x] GCE single-VM setup runs non-clustered Kestra from Docker Compose.
- [x] GCE cluster setup runs multiple VM-backed Kestra components.
- [x] GKE dev setup uses Kustomize overlays and autoscaling-capable manifests.
- [x] `flake.nix` includes required development dependencies.
- [x] README and command docs explain the workflows.
- [x] Available static validation has been executed and results recorded.
- [x] Live GCP apply and live Kestra flow execution are verified with project credentials.
- [ ] Live HTTPS domain delegation and certificate provisioning are verified with a real domain.

## Progress Log

### Session: 2026-06-25 00:00

**Tasks Completed**: Read repo instructions and skill guidance; inspected the project scaffold;
recorded architecture notes and implementation plan.

**Tasks In Progress**: Adding local runtime assets, flows, Terraform, Kustomize manifests, and
tooling updates.

**Blockers**: Live GCP project creation and runtime verification require credentials and billing
account values not present in the repo.

**Notes**: The GCP project creation requirement will be represented in Terraform bootstrap rather
than manually applying cloud resources from this session.

### Session: 2026-06-25 01:00

**Tasks Completed**: Added local Kestra config, Apple container scripts, Docker Compose fallback,
two ecommerce flows, Terraform roots for project bootstrap/GCE single/GCE cluster/GKE dev,
Kustomize base and dev overlay, tooling dependencies, Taskfile commands, and README documentation.
Fixed the Python scaffold module name from `kestra-playground` to `kestra_playground` so repository
checks can run.

**Tasks In Progress**: Live cloud provisioning and live Kestra flow execution.

**Blockers**: Live GCP apply requires a billing account, organization or folder ID, and credentials.
Local runtime verification requires Apple container or Docker access on the developer machine.

**Validation**:
- `bash -n local/apple-container/start.sh local/apple-container/stop.sh local/docker/init-batch-db.sh scripts/register-flows.sh scripts/run-flow.sh`
- `ruby -e 'require "psych"; ...'` over Kestra, local Docker, Kubernetes, and Taskfile YAML
- `nix eval --raw .#devShells.aarch64-darwin.default.drvPath`
- `nix develop -c tofu fmt -check -recursive infra/terraform`
- `nix develop -c tofu validate` in each Terraform root
- `nix develop -c kustomize build k8s/overlays/dev`
- `nix develop -c docker compose --env-file local/docker/.env.example -f local/docker/docker-compose.yml config`
- `nix develop -c shellcheck ...`
- `nix develop -c uv run ruff format .`
- `nix develop -c uv run ruff check .`
- `nix develop -c uv run ty check .`
- `nix develop -c uv run pytest`

### Session: 2026-06-25 02:00

**Tasks Completed**: Re-audited the single-VM requirement and changed `infra/terraform/gce-single`
from Cloud SQL proxy mode to local-like Docker Compose mode with both `postgres:16` and
`kestra/kestra:latest`. Secret Manager still supplies the database connection values to the VM and
Kestra environment file.

**Tasks In Progress**: Live cloud provisioning and live Kestra flow execution.

**Blockers**: Live GCP apply still requires interactive reauthentication before billing accounts can
be listed or attached. Local runtime execution still requires the host container runtime.

**Validation**:
- `bash -n` over local scripts and GCE startup templates
- `nix develop -c shellcheck local/apple-container/start.sh local/apple-container/stop.sh local/docker/init-batch-db.sh scripts/register-flows.sh scripts/run-flow.sh`
- `ruby -e 'require "psych"; ...'` over Kestra, local Docker, Kubernetes, and Taskfile YAML
- `nix develop -c tofu fmt -check -recursive infra/terraform`
- `nix develop -c tofu init -backend=false -input=false` and `nix develop -c tofu validate` in each Terraform root
- `nix develop -c kustomize build k8s/overlays/dev`
- `nix develop -c docker compose --env-file local/docker/.env.example -f local/docker/docker-compose.yml config`
- `nix develop -c uv run ruff check .`
- `nix develop -c uv run ty check .`
- `nix develop -c uv run pytest`

### Session: 2026-06-25 03:00

**Tasks Completed**: Added Docker Compose fallback start/stop wrappers that create an editable
`local/docker/.env` from the example file, made flow registration wait for the Kestra webserver
before posting flow YAML, and hardened the GCE startup scripts to support both `docker compose` and
`docker-compose` package layouts.

**Tasks In Progress**: Live GCP project creation, Terraform apply, and live Kestra execution.

**Blockers**: `gcloud billing accounts list` still cannot complete with the active user because
interactive reauthentication is required. The alternate service-account credential cannot list
billing accounts because the Cloud Billing API is disabled for its quota project and it did not
provide usable billing-account evidence. Creating the new GCP project and attaching billing cannot
be verified from this session without that external account state change.

**Validation**:
- `bash -n` over local scripts and GCE startup templates
- `nix develop -c shellcheck local/apple-container/start.sh local/apple-container/stop.sh local/docker/init-batch-db.sh local/docker/start.sh local/docker/stop.sh scripts/register-flows.sh scripts/run-flow.sh`
- YAML parse over Kestra, local Docker, Kubernetes, and Taskfile YAML
- `nix develop -c tofu fmt -check -recursive infra/terraform`
- `nix develop -c tofu init -backend=false -input=false` and `nix develop -c tofu validate` in each Terraform root
- `nix develop -c kustomize build k8s/overlays/dev`
- `nix develop -c docker compose --env-file local/docker/.env.example -f local/docker/docker-compose.yml config`
- `nix develop -c uv run ruff check .`
- `nix develop -c uv run pytest`
- `nix develop -c uv run ty check .`

### Session: 2026-06-25 04:00

**Tasks Completed**: Created live GCP project `example-project-id`, enabled required APIs,
stored GCP ADC and live Kestra Basic Auth values in `kinko`, applied the single-VM Terraform root,
registered both flows, and verified generator/report executions reached `SUCCESS` on
`http://34.84.21.87:8080`. Applied the GCE cluster Terraform root, fixed startup ordering for Secret
Manager IAM, capped Kestra datasource pools, resized Cloud SQL to `db-g1-small`, moved cluster VMs
to `e2-standard-4`, lowered worker threads, made the MIG rollout proactive, and verified both GCE
cluster backends are healthy behind `http://8.233.46.87`. Registered both flows against the cluster
and verified generator/report executions reached `SUCCESS`.

**Tasks In Progress**: Live HTTPS certificate provisioning and DNS delegation for real
environment-specific subdomains.

**Blockers**: A real parent DNS domain is still required. The Terraform roots contain the DNS,
managed certificate, and HTTPS load balancer resources, but they intentionally do not apply live
HTTPS resources while `domain_name` is empty.

**Validation**:
- Live single-VM Kestra health and flow execution against `http://34.84.21.87:8080`
- Live GCE cluster backend health and flow execution against `http://8.233.46.87`
- `nix develop -c tofu validate` in all Terraform roots
- `nix develop -c kustomize build k8s/overlays/dev`
- `nix develop -c shellcheck ...`
- `nix develop -c uv run ruff check .`
- `nix develop -c uv run ty check`
- `nix develop -c uv run pytest`

### Session: 2026-06-25 05:00

**Tasks Completed**: Re-audited the current repository and live GCP state against the requested
playground scope. Verified project `example-project-id` is active, the single-VM endpoint
serves `http://34.84.21.87:8080/ui/`, both GCE cluster MIG instances are running on the current
template, both cluster load-balancer backends are healthy, and the cluster endpoint serves
`http://8.233.46.87/ui/`. Verified the latest cluster executions for both ecommerce flows remain in
`SUCCESS`.

**Tasks In Progress**: Live HTTPS certificate provisioning and DNS delegation for real
environment-specific subdomains.

**Blockers**: Same as the previous session: live HTTPS needs a real parent DNS domain or an
existing Cloud DNS managed zone name. The Terraform resources are present, but live certificate
issuance cannot be proven until a real hostname is delegated and applied.

**Validation**:
- `gcloud projects describe example-project-id`
- `gcloud compute instances describe kestra-dev-single`
- `gcloud compute instance-groups managed list-instances kestra-cluster-dev-mig`
- `gcloud compute backend-services get-health kestra-cluster-dev-web --global`
- `curl http://34.84.21.87:8080/ui/`
- `curl http://8.233.46.87/ui/`
- Kestra execution API search for `playground.ecommerce`
- `nix develop -c tofu validate` in all Terraform roots
- `nix develop -c kustomize build k8s/overlays/dev`
- Docker Compose render from `local/docker/.env.example`
- YAML parse over Kestra config, flows, local Docker Compose, and Taskfile
- `nix develop -c shellcheck ...`
- `nix develop -c uv run ruff check .`
- `nix develop -c uv run ty check`
- `nix develop -c uv run pytest`

### Session: 2026-06-25 04:00

**Tasks Completed**: Authenticated with `gcloud` using browser-based login, stored ADC credentials
in kinko, created GCP project `example-project-id`, attached billing, enabled required APIs,
applied the single-VM Terraform root, and verified the live Kestra endpoint at
`http://34.84.21.87:8080`. Added Terraform-managed optional HTTPS/domain resources for the GCE
single-VM, GCE cluster, and GKE dev roots. Added explicit Kestra Basic Auth credentials generated
by Terraform and stored in Secret Manager, imported the live Kestra Basic Auth variables into kinko,
made flow registration authenticate and update existing flows idempotently, and fixed current
Kestra 1.3 flow validation/runtime issues.

**Tasks In Progress**: Waiting for a real parent domain/subdomain choice before applying live HTTPS
DNS and certificate resources.

**Blockers**: Live HTTPS cannot be verified until a parent DNS domain is provided and delegated to
the Cloud DNS name servers, or an existing Cloud DNS managed zone is selected.

**Validation**:
- `nix develop -c tofu apply -var=project_id=example-project-id` in `infra/terraform/gce-single`
- `curl -u ... http://34.84.21.87:8080/`
- `scripts/register-flows.sh http://34.84.21.87:8080`
- Live Kestra execution `generate_ecommerce_mock_data` reached `SUCCESS`
- Live Kestra execution `build_ecommerce_daily_report` reached `SUCCESS`
- PostgreSQL sanity check returned 80 orders and 9 report rows for `2026-06-25`
- `bash -n scripts/register-flows.sh scripts/run-flow.sh`
- `shellcheck scripts/register-flows.sh scripts/run-flow.sh`
- YAML parse over Kestra flows/config, local Docker, and Kubernetes manifests
- `nix develop -c tofu fmt -recursive infra/terraform`
- `nix develop -c tofu validate` for `gce-single`, `gce-cluster`, and `gke-dev`
- `nix develop -c kustomize build k8s/overlays/dev`

### Session: 2026-06-25 05:00

**Tasks Completed**: Audited the optional HTTPS load-balancer health checks against the live Kestra
server. Because `/` returns HTTP 307 and `/ui/` returns HTTP 200, changed the GCE single-VM and GCE
cluster Terraform health checks to `/ui/`. Added a GKE BackendConfig health check on `/ui/` and
patched the dev overlay Service to use container-native load balancing through a NEG-backed
`ClusterIP` Service. Aligned local Kestra Basic Auth configuration with the live configuration and
made flow helper scripts load URL/auth values from `KESTRA_ENV_FILE`; Taskfile flow commands now
choose the local Docker env file or Apple-container env file automatically. Fixed the GCE cluster
Cloud SQL JDBC URLs to target the Docker Compose `cloud-sql-proxy` service instead of each Kestra
container's loopback address; the GKE sidecar path intentionally remains `127.0.0.1`. Verified the
current `kestra/kestra:latest` server subcommands and changed separated worker commands from the
standalone-only `--worker-thread` flag to `server worker --thread`.

**Tasks In Progress**: Waiting for a real parent domain/subdomain choice before applying live HTTPS
DNS and certificate resources.

**Blockers**: Live HTTPS cannot be verified until a parent DNS domain is provided and delegated to
the Cloud DNS name servers, or an existing Cloud DNS managed zone is selected.

**Validation**:
- `curl http://34.84.21.87:8080/` returned HTTP 307
- `curl http://34.84.21.87:8080/ui/` returned HTTP 200
- URL audit confirms GCE cluster uses `jdbc:postgresql://cloud-sql-proxy:5432/...` while GKE
  sidecars use `jdbc:postgresql://127.0.0.1:5432/...`
- Current `kestra/kestra:latest` help confirms `server worker --thread` and the separated server
  subcommands: `webserver`, `executor`, `scheduler`, `indexer`, and `worker`
- `bash -n` and `shellcheck` over local/runtime helper scripts
- YAML parse over Kestra, local Docker, Kubernetes, and Taskfile YAML
- Docker Compose render with `local/docker/.env.example`
- `nix develop -c tofu fmt -check -recursive infra/terraform`
- `nix develop -c tofu validate` in all four Terraform roots
- `nix develop -c kustomize build k8s/overlays/dev`
- `nix develop -c uv run ruff check .`
- `nix develop -c uv run ty check .`
- `nix develop -c uv run pytest`

### Session: 2026-06-25 06:00

**Tasks Completed**: Added root-specific `terraform.tfvars.example` files for the optional
domain/subdomain HTTPS path in the GCE single-VM, GCE cluster, and GKE dev Terraform roots.
Documented the example file flow in the README. Hardened the GCE single-VM Terraform dependency so
the VM startup script waits for Secret Manager IAM before reading runtime secrets.

**Tasks In Progress**: Waiting for a real parent domain/subdomain choice before applying live HTTPS
DNS and certificate resources.

**Blockers**: Live HTTPS cannot be verified until a parent DNS domain is provided and delegated to
the Cloud DNS name servers, or an existing Cloud DNS managed zone is selected.

**Validation**:
- `nix develop -c tofu fmt -recursive infra/terraform`
- `nix develop -c tofu validate` in all four Terraform roots
- `nix develop -c kustomize build k8s/overlays/dev`
- `nix develop -c bash -n ...` over runtime helper scripts
- `nix develop -c shellcheck ...` over runtime helper scripts
- `nix develop -c uv run ruff check .`
- `nix develop -c uv run ty check`
- `nix develop -c uv run pytest`
- `nix develop -c tofu -chdir=infra/terraform/gce-single plan -detailed-exitcode -var=project_id=example-project-id`
  returned exit code 0, confirming no live single-VM infrastructure drift after the dependency
  hardening.

### Session: 2026-06-25 11:20

**Tasks Completed**: Used the Cloudflare zone `example.com` for live HTTPS DNS. Created and
stored the scoped Cloudflare DNS-edit API token in `kinko` as `CLOUDFLARE_API_TOKEN`. Added
Cloudflare DNS provider support to the GCE single-VM, GCE cluster, and GKE dev Terraform roots.
Applied the live HTTPS configuration for:

- GKE: `https://k8s.example.com`
- GCE clustered container environment: `https://gce-container.example.com`
- GCE single VM Docker Compose environment: `https://gce-compose.example.com`

Created the GKE Autopilot environment, Cloud SQL database, GCS bucket, Workload Identity binding,
Cloudflare DNS A record, GKE ingress, and GKE ManagedCertificate. Added
`scripts/apply-gke-dev.sh` so sensitive Kubernetes Secret values are rendered only into a temporary
manifest from Terraform outputs. Added the GKE auth plugin to the Nix dev shell.

**Tasks In Progress**: None.

**Blockers**: None.

**Validation**:
- `kinko exec --env CLOUDFLARE_API_TOKEN -- curl https://api.cloudflare.com/client/v4/user/tokens/verify`
  returned success.
- DNS resolves:
  - `k8s.example.com` -> `<gke-ingress-ip>`
  - `gce-container.example.com` -> `<gce-cluster-ip>`
  - `gce-compose.example.com` -> `<gce-single-ip>`
- GKE `ManagedCertificate` is `Active` and `curl -fsSI https://k8s.example.com/ui/` returned
  HTTP 200.
- GCE Google-managed certificates `kestra-cluster-dev-https` and `kestra-dev-https` are `ACTIVE`.
- `curl -fsSI https://gce-container.example.com/ui/` returned HTTP 200.
- `curl -fsSI https://gce-compose.example.com/ui/` returned HTTP 200.
- `kubectl -n kestra-dev get pods` showed all Kestra pods `Running`.
- `tofu plan -detailed-exitcode` returned 0 for `gce-single`, `gce-cluster`, and `gke-dev` with the
  live Cloudflare domain variables.
- `tofu validate` passed for `gce-single`, `gce-cluster`, and `gke-dev`.
- `shellcheck scripts/*.sh`, `kustomize build k8s/overlays/dev`, and `nix flake check --no-build`
  passed.

### Session: 2026-06-25 11:50

**Tasks Completed**: Performed end-to-end runtime verification in each live HTTPS environment by
registering the two ecommerce flows and executing both the mock data generator and daily report
flows. Fixed the GKE manifests so Kestra containers wait for the Cloud SQL proxy sidecar to accept
connections on `127.0.0.1:5432` before starting; without this, the fresh GKE executor accepted
executions but left them in `CREATED`.

**Tasks In Progress**: None.

**Blockers**: None.

**Validation**:
- `https://gce-compose.example.com/ui/` returned HTTP 200; executions:
  - `generate_ecommerce_mock_data`: `SUCCESS` (`2CPuJYw4ln8mkV87AyGJBz`)
  - `build_ecommerce_daily_report`: `SUCCESS` (`SlaLGzwByth6PjmZsKtuB`)
- `https://gce-container.example.com/ui/` returned HTTP 200; executions:
  - `generate_ecommerce_mock_data`: `SUCCESS` (`2dduRnVO80YO7wPedLlKmz`)
  - `build_ecommerce_daily_report`: `SUCCESS` (`6wYIvj8sjW8b1wVnCAifFH`)
- `https://k8s.example.com/ui/` returned HTTP 200 after the sidecar wait fix; executions:
  - `generate_ecommerce_mock_data`: `SUCCESS` (`2GeXsDr612Axo58iEMM4ou`)
  - `build_ecommerce_daily_report`: `SUCCESS` (`7838bmFWvDZSRPFL6yj72N`)
- `kubectl -n kestra-dev wait --for=condition=Ready pod -l app.kubernetes.io/component=webserver`
  confirmed all webserver pods Ready.
- `shellcheck scripts/*.sh`, `kustomize build k8s/overlays/dev`, and
  `tofu -chdir=infra/terraform/gke-dev validate` passed.

### Session: 2026-06-25 12:05

**Tasks Completed**: Added git-managed ecommerce fixture SQL under
`kestra/fixtures/ecommerce/` and a pytest guard that verifies the generator flow stays synchronized
with those fixtures. Added committed live dev tfvars for the three HTTPS environments. Added
`scripts/deploy-live-environments.sh` and `scripts/verify-live-environments.sh` so manual and CI
operations use the same deploy, HTTPS check, flow registration, and batch execution path. Added a
GitHub Actions workflow that validates the repo, deploys on push/manual dispatch, and executes the
batch on cron or manual request. Added the `infra/terraform/github-actions` root for GitHub OIDC and
applied it to create the deploy service account, Workload Identity provider, and IAM grants. Set the
required GitHub repository secrets:

- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT`
- `CLOUDFLARE_API_TOKEN`

**Tasks In Progress**: None.

**Blockers**: None.

**Validation**:
- `scripts/verify-live-environments.sh all 2026-06-25 run-batch` passed for all live HTTPS
  environments. Executions:
  - `gce-compose`: generator `SUCCESS` (`6YaXyuIOlWbWMLphYsVZJY`), report `SUCCESS`
    (`qZTZ8bUDHzlvMuhTzAXbR`)
  - `gce-container`: generator `SUCCESS` (`znqrtaeU0BCLuCICdU0FX`), report `SUCCESS`
    (`yRjYDCIvOrLrslkXqg9yZ`)
  - `k8s`: generator `SUCCESS` (`1njsBlkAdmdqzQptTgPy5x`), report `SUCCESS`
    (`6s8ViSH3P3QdAernXzizEP`)
- `task ci` passed: Ruff format check, Ruff lint, ty type check, pytest, and package build.
- `shellcheck scripts/*.sh` passed.
- `tofu fmt -check -recursive infra/terraform` and `tofu fmt -check -recursive infra/live` passed.
- `tofu validate` passed for `gce-single`, `gce-cluster`, `gke-dev`, and `github-actions`.
- `kustomize build k8s/overlays/dev` passed.
- `tofu plan -detailed-exitcode` returned 0 for `gce-single`, `gce-cluster`, `gke-dev`, and
  `github-actions`, confirming no live infrastructure drift.
