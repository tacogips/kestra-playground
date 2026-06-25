# Architecture Design

This document describes system architecture and design decisions.

## Overview

Architectural patterns, system structure, and technical decisions.

---

## Sections

(Add architecture design sections below)

---

## Kestra Deployment Playground

This repository is a playground for running the same Kestra ecommerce mock batch workload across
four deployment shapes:

1. Local Apple container runtime using PostgreSQL and file-based Kestra configuration.
2. GCP single-VM deployment managed by Terraform, with a new GCP project, Secret Manager, and
   Docker Compose on GCE running both Kestra and PostgreSQL.
3. GCP multi-VM Kestra cluster using separate Kestra server components, Cloud SQL, shared GCS
   internal storage, and a load-balanced webserver tier.
4. GKE Autopilot development deployment using Kustomize base manifests plus environment overlays.

### Workload

The workload namespace is `playground.ecommerce`.

- `generate_ecommerce_mock_data` creates product, customer, order, order item, payment, inventory,
  and support ticket mock data for ecommerce operations.
- `build_ecommerce_daily_report` reads the mock tables and emits an operational daily report into
  `ecommerce_daily_reports`, with rows returned in the Kestra execution output.

Both flows use the PostgreSQL JDBC plugin and read their target business database from Kestra
environment variables:

| Environment variable | Purpose |
|----------------------|---------|
| `ENV_BATCH_DB_URL` | JDBC URL for the ecommerce batch database |
| `ENV_BATCH_DB_USERNAME` | Batch database user |
| `ENV_BATCH_DB_PASSWORD` | Batch database password |

Local and GCP deployments switch values through environment files or platform secrets. Kestra's own
repository and queue database is separate from the ecommerce batch database in GCP, but local
development uses the same PostgreSQL container with separate databases.

### Local Runtime

The primary local target is Apple container. The scripts under `local/apple-container/` start:

- a `postgres:16` container with named volumes;
- a `kestra/kestra:latest` standalone container with `kestra/config/application.yaml`;
- a shared Apple container network for service DNS.

`local/docker/docker-compose.yml` is kept as a fallback for machines where Docker Compose is still
more convenient than Apple container.

### GCP Single VM

`infra/terraform/gce-single` creates a VM that runs Docker Compose for Kestra and PostgreSQL.
Terraform also creates a new GCP project when paired with `infra/terraform/bootstrap-project`,
Secret Manager secrets for database connection values, and a service account that can read only the
required secrets.

The VM shape is intentionally simple and non-clustered: one GCE instance, one Kestra standalone JVM,
and one PostgreSQL container with a persistent Docker volume.

When `domain_name` is set, the root also creates a Google HTTPS load balancer, a Google-managed SSL
certificate, a static global IP address, and a Cloud DNS A record for the environment subdomain.

### GCP GCE Cluster

`infra/terraform/gce-cluster` validates the cluster path by creating multiple GCE instances. Each VM
runs a multi-component Docker Compose stack with webserver, executor, scheduler, indexer, and worker
services. All instances share:

- Cloud SQL PostgreSQL for Kestra repository and queue;
- Cloud SQL PostgreSQL for ecommerce batch data;
- GCS for Kestra internal storage;
- Secret Manager for database credentials.

The webserver component is exposed through an HTTP load balancer. This is still an infrastructure
playground, so defaults are intentionally dev-sized and deletion protection is disabled.

When `domain_name` is set, the cluster root adds a parallel HTTPS load balancer and DNS record for
the requested environment subdomain.

### GKE Development Manifests

`k8s/base` contains raw Kubernetes manifests for separate Kestra components, a Cloud SQL Auth Proxy
sidecar, a webserver Service, and worker/webserver autoscaling. `k8s/overlays/dev` adds development
namespace, labels, replica counts, resource bounds, and Workload Identity annotations.

The overlay model is Kustomize-based so later environments can override the base without copying the
entire manifest tree.

For HTTPS, `infra/terraform/gke-dev` can reserve a global static IP and create the Cloud DNS record.
The dev overlay includes a GKE `ManagedCertificate` and Ingress placeholder that are patched with
the Terraform hostname and static IP name before apply.
