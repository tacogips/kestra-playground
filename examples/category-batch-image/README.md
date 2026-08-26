# Category Batch Image Routing Example

This example packages two `orders` category batches in one OCI image. The Kestra flow selects one
script from that image per task. The normal task has no `workerSelector` and therefore uses the
default worker queue; only the special task is routed to the single-replica `gke-large` Worker Group.

```text
one category image
  |-- normal_batch.sh  -> default worker queue (no workerSelector)
  `-- special_batch.sh -> workerSelector tag gke-large
```

The image is immutable in deployments: GitHub Actions publishes a commit-SHA tag and injects that
exact reference as `envs.category_batch_image`. The mutable `main` tag is only a convenience tag.

The image also owns `/app/batches/version.sh`. It returns the category, semantic version, source
revision, and executing worker host as JSON. On-premises deployments use that executable both as a
post-load health check and as the scheduled per-worker version probe.

On GKE, `PodCreate` starts each selected batch as a Kubernetes Pod because GKE nodes use containerd,
not a Podman or Docker API socket. The `PodCreate` Kestra task itself executes on the selected Kestra
worker. Kubernetes schedules the child batch Pod independently; add a `nodeSelector` to its Pod spec
if the batch container must also run in a particular node placement domain.

Run the live verification after deploying the routed topology:

```bash
mise run kestra:live:run-category-batch-image-routing
```

The verifier checks both task states, distinct Kestra worker IDs, the shared immutable image used by
both Pods, and the batch-specific log markers before deleting the example Pods.

The companion `verify_worker_local_file_handoff` flow routes both ordered Process tasks to the
single-replica `gke-large` StatefulSet. The first task writes to its mounted worker-local volume and
the second task reads and removes the file. A live negative case skips the writer and verifies that
the reader fails. Run it with:

```bash
mise run kestra:live:run-worker-local-file-handoff
```

For the registry-free on-premises deployment, build an immutable release archive and distribute it
only to the category's worker inventory group:

```bash
podman build \
  --build-arg LOGIC_VERSION=1.1.0 \
  --build-arg REVISION="$(git rev-parse HEAD)" \
  --tag localhost/kestra-category/orders:1.1.0 \
  examples/category-batch-image
podman save --format oci-archive \
  --output orders-1.1.0.oci \
  localhost/kestra-category/orders:1.1.0

scripts/deploy-category-logic-ansible.sh \
  ops/ansible/category-logic/inventory.ini \
  orders_workers \
  orders-1.1.0.oci \
  localhost/kestra-category/orders:1.1.0 \
  1.1.0 \
  "$(git rev-parse HEAD)"
```

This loads only the category image. It neither reloads nor restarts the Kestra worker image.
See [the on-premises deployment design](../../design-docs/specs/design-onprem-category-logic-deployment.md)
for deployment, monitoring, rollback, and host prerequisites.
