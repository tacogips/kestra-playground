# Shared Batch Library and Private Python Registry Operation

How `kestra-batch-common` (the shared library used by every Python batch) is developed
locally from the top-level source tree, published to the private GCP Artifact Registry,
and consumed by staging/production workers.

## Overview

Every batch under `batch-groups/*/batches/` is its own uv project that depends on
`kestra-batch-common`, the shared runtime library at the repository top level
(`batch-common/`). One dependency declaration serves two resolution modes:

- **Local development** resolves the library from the working tree through a
  `tool.uv.sources` path entry (editable), so library edits are visible immediately.
- **Staging / production** resolves the published wheel from the private GCP
  Artifact Registry Python repository, either with `uv --no-sources` plus `UV_INDEX`
  environment variables (uv-managed workers) or with `pip install --index-url`
  (SSH batch targets).

The switch is never a file edit: the same `pyproject.toml` is used everywhere, and the
environment decides the source.

## Details

### Components

| Component | Path | Role |
|-----------|------|------|
| Shared library | `batch-common/` | `kestra-batch-common` source, tests, own `uv.lock` |
| Batch projects | `batch-groups/*/batches/*/pyproject.toml` | Per-batch dependency pin plus path source override |
| Registry | Artifact Registry `python-batch-libs` (PYTHON format) | Staging/production package source |
| Registry IaC | `infra/terraform/artifact-registry/` | Repository and reader/writer IAM |
| Publish script | `scripts/publish-batch-common.sh` | Test, build, and upload one version |
| Worker image | `local/docker/remote-worker/Dockerfile` | Local SSH workers install from the working tree |
| Live SSH targets | `scripts/live-remote-batch-target-startup.sh` | Install from the registry via instance metadata |
| Routed runner | `kestra/flows-remote-batch/01_routed_batch_runner.yaml` | `dependency_source` input: `bundled` or `registry` |

### Batch project contract

Each batch declares the dependency with an exact pin and a path override:

```toml
[project]
dependencies = ["kestra-batch-common==0.1.0"]

[tool.uv.sources]
kestra-batch-common = { path = "../../../../batch-common", editable = true }
```

Rules:

- Always pin an exact version (`==X.Y.Z`). The pinned version must exist in the
  registry before the batch reaches staging/production.
- A batch that needs an older library version simply keeps an older pin; other
  batches are unaffected because every batch resolves independently.
- The top-level `pyproject.toml` dev group also carries the path source so
  `uv run pytest` can execute batch scripts directly.

### Resolution matrix

| Environment | Mechanism | Library source |
|-------------|-----------|----------------|
| Developer machine (`uv run` in a batch directory) | `tool.uv.sources` path entry | `batch-common/` working tree (editable) |
| Repository test suite (`uv run pytest`) | top-level dev group path source | `batch-common/` working tree (editable) |
| Local Docker SSH workers (flows `remote_batch_runner`, multi-target) | image build `pip install /opt/batch-common` | working tree copied at image build |
| Routed workers, `dependency_source: bundled` (default) | bundle ships `batch-common/` at the path-source location | bundle copy of the working tree |
| Routed workers, `dependency_source: registry` | `uv run --no-sources` + `UV_INDEX*` env on the worker | Artifact Registry |
| Live SSH targets (GCE) | startup-script `pip install --index-url ...` | Artifact Registry |

Routed bundles mirror the repository layout (`batch-groups/<group>/batches/<batch>/` plus
`batch-common/` at the bundle root) so the relative path source resolves identically
inside the extracted bundle. `scripts/build-remote-batch-bundles.sh` produces them.

### Provisioning the registry

```bash
cd infra/terraform/artifact-registry
tofu init
tofu apply \
  -var "project_id=${PROJECT_ID}" \
  -var 'reader_members=["serviceAccount:<worker-sa>@<project>.iam.gserviceaccount.com"]' \
  -var 'writer_members=["user:<publisher>@example.com"]'
```

Outputs include `python_index_url` (install side) and `python_upload_url` (publish side).
Grant `roles/artifactregistry.reader` to every service account that installs
(GKE worker node SA, GCE SSH target SA) and `roles/artifactregistry.writer` to
publishers. SSH target instances are created with the `cloud-platform` OAuth scope by
`scripts/provision-live-remote-batch-targets.sh`; IAM remains the effective boundary.

### Publishing a new library version

1. Change code in `batch-common/`, add or update tests.
2. Bump `version` in `batch-common/pyproject.toml` (the registry rejects re-uploads
   of an existing version; every change needs a new version).
3. Publish:

   ```bash
   PROJECT_ID=<project> mise run batch-common:publish
   # or scripts/publish-batch-common.sh
   ```

   The script runs the test suite, builds with `uv build`, and uploads with
   `uv publish` using `oauth2accesstoken` and the active gcloud credential.
4. Update the pins in the batch projects that should adopt the new version, and
   refresh each batch lock: `cd batch-groups/<g>/batches/<b> && uv lock`.
5. Deploy the batches as usual. Batches that keep an old pin keep resolving the old
   wheel from the registry.

Invariant: the working tree of `batch-common/` at version `X.Y.Z` must match the
published `X.Y.Z` wheel. Publish before merging pin bumps, and never edit library
behavior without bumping the version.

### Configuring staging/production uv workers (registry mode)

Routed executions opt into the registry with the `dependency_source: registry` flow
input. The worker environment (Kubernetes Deployment env or equivalent) must provide:

```bash
UV_INDEX="gcp-python=https://asia-northeast1-python.pkg.dev/${PROJECT_ID}/python-batch-libs/simple/"
UV_INDEX_GCP_PYTHON_USERNAME=oauth2accesstoken
UV_INDEX_GCP_PYTHON_PASSWORD=<short-lived access token>
```

On GKE, mint the token from the metadata server (or use a sidecar/refresh hook);
tokens expire after roughly one hour, so long-lived workers need refresh-on-start
task commands or workload-identity-based keyring auth
(`keyrings.google-artifactregistry-auth`) baked into the worker image.

### Configuring live SSH batch targets (registry mode)

`scripts/provision-live-remote-batch-targets.sh` forwards two optional environment
variables into instance metadata:

```bash
PYTHON_REGISTRY_INDEX_URL="https://asia-northeast1-python.pkg.dev/${PROJECT_ID}/python-batch-libs/simple/" \
KESTRA_BATCH_COMMON_SPEC="kestra-batch-common==0.1.0" \
scripts/provision-live-remote-batch-targets.sh up
```

The startup script installs the library with the instance service account token.
When the metadata is absent the install is skipped, which keeps registry-less
experiments possible; the SSH flows then fail at import time, making the missing
dependency explicit.

### Local environments

No configuration is needed. Batch directories resolve the path source; the local
Docker worker image copies `batch-common/` at build time (rebuild with
`docker compose build remote-worker remote-worker-b` after library changes); routed
bundles default to `dependency_source: bundled`.

### Adding a new batch

1. Create `batch-groups/<group>/batches/<name>/` with the script and a
   `pyproject.toml` following the contract above (adjust the relative path depth).
2. Run `uv lock` in the batch directory and commit the lock.
3. Import shared behavior from `kestra_batch_common` instead of copying helpers.

## References

- `design-docs/specs/design-remote-python-batch-runner.md` (runner framework)
- `design-docs/specs/design-per-category-batch-group-cicd.md` (deploy independence)
- uv docs: `tool.uv.sources`, `--no-sources`, `UV_INDEX*` variables, `uv publish`
- GCP docs: Artifact Registry Python repositories, authentication with
  `oauth2accesstoken`

See `design-docs/references/README.md`.
