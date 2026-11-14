# Design Notes

This document contains research findings, investigations, and miscellaneous design notes.

## Overview

Notable items that do not fit into architecture or client categories.

---

## Sections

(Add design notes sections below)

---

## Kestra Deployment Notes

- Kestra's Docker Compose documentation shows standalone mode backed by PostgreSQL and a
  config-file option mounted into `/etc/config/application.yaml`.
- Kestra can run individual server components with `kestra server webserver`, `executor`, `worker`,
  `scheduler`, and `indexer`; the GCE cluster and GKE manifests use that component split.
- The local Apple container path uses explicit `container run` commands because Apple container does
  not provide a native Compose feature in the official command reference.
- The Terraform roots are intentionally separate:
  - `bootstrap-project` creates a new GCP project and enables services.
  - `gce-single` deploys the non-clustered VM shape.
  - `gce-cluster` deploys multi-VM Kestra components.
  - `gke-dev` deploys GKE Autopilot and managed backing services.
- Cloud resources default to dev-sized settings and `deletion_protection = false`; production
  evaluation must revisit availability, backups, IAM boundaries, ingress authentication, TLS, and
  persistent state retention.
- HTTPS/domain support is optional and parameterized by `domain_name`. If Terraform creates a new
  Cloud DNS managed zone, the registrar or parent zone still needs NS delegation to the output name
  servers before Google-managed certificates can become active.
