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
local/apple-container/stop.sh
```

### Local Docker Compose Fallback

```bash
docker compose --env-file local/docker/.env.example -f local/docker/docker-compose.yml up -d
scripts/register-flows.sh http://localhost:8080
docker compose -f local/docker/docker-compose.yml down
```

### Terraform Project Bootstrap

```bash
cd infra/terraform/bootstrap-project
terraform init
terraform apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='billing_account=XXXXXX-XXXXXX-XXXXXX' \
  -var='org_id=123456789012'
```

### Terraform GCE Single VM

```bash
cd infra/terraform/gce-single
terraform init
terraform apply -var='project_id=kestra-playground-dev-<unique-suffix>'
```

With HTTPS domain resources:

```bash
terraform apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='domain_name=example.com' \
  -var='subdomain=dev'
```

### Terraform GCE Cluster

```bash
cd infra/terraform/gce-cluster
terraform init
terraform apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='cluster_size=2'
```

With HTTPS domain resources:

```bash
terraform apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='cluster_size=2' \
  -var='domain_name=example.com' \
  -var='subdomain=cluster-dev'
```

### Terraform GKE Dev

```bash
cd infra/terraform/gke-dev
terraform init
terraform apply -var='project_id=kestra-playground-dev-<unique-suffix>'
gcloud container clusters get-credentials kestra-dev --region asia-northeast1
kustomize build k8s/overlays/dev | kubectl apply -f -
```

For GKE HTTPS, pass `domain_name` and `subdomain`, then patch the dev overlay using
`ingress_static_ip_name` and `kestra_https_url` outputs before `kubectl apply`.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| (Add more exit codes as needed) | |

---
