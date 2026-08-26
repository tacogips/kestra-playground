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
