---
name: kestra-gcp-operations
description: Operate, deploy, verify, or troubleshoot this repository's Kestra playground on GCP. Use when Codex is asked to work with Kestra flows, Artifact Registry runtime images, GitHub Actions deployment, OpenTofu/Terraform live roots, Cloudflare-backed subdomains, GCE single or clustered environments, GKE dev manifests, Secret Manager values, live batch execution, or UI verification for gce-compose, gce-container, or k8s environments.
---

# Kestra GCP Operations

## Overview

Use this skill to operate the Kestra playground consistently across local Docker, GCE single VM,
GCE cluster, and GKE dev environments. Treat `design-docs/specs/command.md` as the authoritative
runbook and update it when operational behavior changes.

## First Steps

1. Read `design-docs/specs/command.md`, especially `Kestra GCP Operations Runbook`.
2. Read `design-docs/specs/architecture.md` when changing ownership boundaries, runtime topology,
   Terraform roots, DNS, or secret flow.
3. Inspect the current working tree with `git status --short`; do not revert unrelated user changes.
4. Run commands through `nix develop -c` unless already inside the Nix shell.

## Environment Map

Use these target names consistently:

| Target | Alias | URL | Root |
|--------|-------|-----|------|
| `gce-compose` | `gce-single` | `https://gce-compose.example.com` | `infra/terraform/gce-single` |
| `gce-container` | `gce-cluster` | `https://gce-container.example.com` | `infra/terraform/gce-cluster` |
| `k8s` | `gke-dev` | `https://k8s.example.com` | `infra/terraform/gke-dev` |

The live project is `example-project-id`; the primary region is `asia-northeast1`.

## Standard Workflow

For code or flow changes:

1. Update flows, fixtures, scripts, docs, or Terraform with small scoped edits.
2. Run `nix develop -c task ci`.
3. Run infrastructure checks relevant to the change:
   - `nix develop -c shellcheck scripts/*.sh`
   - `nix develop -c tofu fmt -check -recursive infra/terraform`
   - `nix develop -c kustomize build k8s/overlays/dev`
   - `nix develop -c kubectl version --client=true`
4. For live deploys, prefer GitHub Actions on push to `main`.
5. For local live redeploys, use `kinko exec --env CLOUDFLARE_API_TOKEN -- task kestra:live:deploy`.
6. Verify with `task kestra:live:verify`; use `task kestra:live:run-batch` when batch behavior must be
   proven.

## Runtime Image Releases

GitHub Actions builds and pushes:

```text
asia-northeast1-docker.pkg.dev/example-project-id/kestra-playground/kestra-runtime:<git-sha>
asia-northeast1-docker.pkg.dev/example-project-id/kestra-playground/kestra-runtime:latest
```

Deploy scripts pass the SHA-tagged image through `KESTRA_IMAGE`. For manual redeploys, set
`KESTRA_IMAGE` explicitly and keep the value out of Terraform variable files unless the requested
change is to update the committed desired image.

## Secrets

Never print live secret payloads in the final answer or commit them to files. Use Secret Manager,
GitHub Actions secrets, or `kinko` injection.

When validating secret plumbing, check metadata or key names instead of values:

- Secret Manager version state with `gcloud secrets versions list`.
- Kubernetes secret key set with `kubectl -n kestra-dev get secret kestra-secrets -o json | jq`.
- Terraform plans with `kinko exec --env CLOUDFLARE_API_TOKEN -- tofu ... plan`.

Expected live Basic Auth secret prefixes:

- `kestra-dev-kestra-basic-auth-*` for `gce-compose`.
- `kestra-cluster-dev-kestra-basic-auth-*` for `gce-container`.
- `kestra-dev-gke-kestra-basic-auth-*` for `k8s`.

## UI Verification

When the user asks to touch or visually verify Kestra, use the Brave Browser Computer Use skill and
operate Brave through `mcp__computer_use`. Do not replace required Computer Use verification with
curl, Playwright, or API calls unless the user explicitly changes the requirement.

For each live target:

1. Open the target URL in Brave.
2. Log in with Basic Auth credentials sourced from Secret Manager without displaying the values.
3. Open `playground.ecommerce/build_ecommerce_customer_segments`.
4. Confirm recent executions show `SUCCESS`.
5. Record which targets were visibly verified.

If Computer Use fails at the MCP or macOS accessibility layer, continue with API and infrastructure
checks, but report the UI verification as blocked rather than complete.

## Documentation

When operations procedures change, update:

- `design-docs/specs/command.md` for commands and runbooks.
- `design-docs/specs/architecture.md` for ownership boundaries and topology decisions.
- `design-docs/specs/notes.md` for caveats, observed behavior, and operational gotchas.
