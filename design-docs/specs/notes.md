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
- The live development domain path uses Cloudflare DNS values injected from `kinko` or CI
  secrets/variables. Do not commit real project, domain, Cloudflare zone, or state bucket values.
- Live HTTPS targets use one shared Cloud Armor policy for rate limiting. Keep one policy unless
  environment-specific thresholds are needed, because duplicated policies add avoidable monthly
  fixed cost.
- Scheduled and default helper-script batch runs use the current date in `Asia/Tokyo`. Historical
  replays should pass `BUSINESS_DATE=YYYY-MM-DD` explicitly; invalid date strings fail before a
  Kestra execution is created.
- `task kestra:live:verify` is a health and flow-registration check only. Use
  `task kestra:live:run-batch` when the deployment must prove the ecommerce batch can write and read
  the business database.
- UI verification is separate from API verification. When the user asks to touch the live Kestra UI,
  use Brave Browser through Computer Use, avoid printing secret values, and verify each public
  subdomain independently.
- The GKE secret render path is intentionally temporary-file based. If that helper fails, inspect the
  temporary render and Kubernetes Secret key set, but do not commit rendered secret manifests.
- GKE OTEL currently exports to the in-cluster collector's `debug` exporter. This proves Kestra can
  emit and the cluster can receive OTLP telemetry; add a vendor-specific exporter later when a
  durable observability backend is chosen.
