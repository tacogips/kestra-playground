# On-Premises Category Logic Deployment

This design deploys a category-owned OCI image to multiple Podman worker hosts without a registry
and without restarting the long-running Kestra worker or unrelated web containers.

## Success Criteria

- One immutable archive is loaded on every host in the selected Ansible inventory group.
- The image-owned version task reports the expected version and Git revision on every host.
- The Kestra worker container ID and `StartedAt` value remain unchanged during deployment.
- A periodic audit detects a missing image, an outdated image, a stopped worker, or a version drift.
- Updating one category does not load or restart images belonging to other categories.

## Architecture

```text
Git tag / commit
       |
       v
CI build: orders:<version> + version.sh
       |
       v
immutable OCI archive + SHA-256
       |
       v
Ansible controller -- parallel copy/load --> orders worker host A
                   |                         - Kestra worker (unchanged)
                   |                         - orders image vN
                   `-----------------------> orders worker host B
                                             - Kestra worker (unchanged)
                                             - orders image vN

Kestra scheduler -- broadcast workerSelector --> version.sh on A and B
systemd timer    -- Ansible inventory audit --> version.sh on A and B
```

The Kestra runtime image and the category logic image have independent lifecycles. `podman load`
updates only local image storage; it does not replace a running worker container. A subsequent batch
task starts a new short-lived container from the immutable category image reference.

## Release and Activation

Use two phases:

1. Stage the new immutable image on all selected workers with Ansible.
2. After every host passes validation, update the Flow to reference the new immutable image tag.

Do not use `latest` in a Flow. Staging first prevents a Flow from selecting a version that is absent
on one of the workers. The playbook uses `any_errors_fatal`, validates the transferred SHA-256,
runs `/app/batches/version.sh`, and then asserts that the worker identity did not change.

```bash
cp ops/ansible/category-logic/inventory.example.ini \
  ops/ansible/category-logic/inventory.ini

podman build \
  --build-arg LOGIC_VERSION=1.1.0 \
  --build-arg REVISION="$(git rev-parse HEAD)" \
  --tag localhost/kestra-category/orders:1.1.0 \
  examples/category-batch-image
podman save --format oci-archive \
  --output orders-1.1.0.oci \
  localhost/kestra-category/orders:1.1.0

CATEGORY_LOGIC_INVENTORY=ops/ansible/category-logic/inventory.ini \
CATEGORY_LOGIC_TARGET_GROUP=orders_workers \
CATEGORY_LOGIC_ARCHIVE=orders-1.1.0.oci \
CATEGORY_LOGIC_IMAGE=localhost/kestra-category/orders:1.1.0 \
CATEGORY_LOGIC_VERSION=1.1.0 \
CATEGORY_LOGIC_REVISION="$(git rev-parse HEAD)" \
mise run kestra:category-logic:deploy
```

An inventory group is the deployment boundary. Create one group per category when host membership
differs. The default `ANSIBLE_FORKS=20` loads multiple hosts concurrently and can be reduced for a
constrained network.

## Periodic Monitoring

Two independent probes are provided:

- `kestra/flows-onprem/monitor_category_logic_versions.yaml` runs every five minutes. Its
  `broadcast: true` selector executes once on every worker advertising `onprem-orders`, fails on any
  version mismatch, and records the worker host/version/revision in task outputs.
- `category-logic-version-audit.timer` runs the Ansible audit from an operations host every five
  minutes. It also confirms that each named worker container is running.

Register the on-premises flow explicitly after setting its immutable image, version, and revision.
It is intentionally outside `flows-worker-routing` so GKE verification does not register it.

For the systemd probe:

```bash
sudo install -m 0644 ops/systemd/category-logic-version-audit.service /etc/systemd/system/
sudo install -m 0644 ops/systemd/category-logic-version-audit.timer /etc/systemd/system/
sudo install -m 0600 ops/systemd/category-logic-audit.env.example \
  /etc/kestra/category-logic-audit.env
sudo systemctl daemon-reload
sudo systemctl enable --now category-logic-version-audit.timer
```

Send failed Kestra executions or failed systemd units to the existing alerting system. The Ansible
audit can also be invoked directly with `mise run kestra:category-logic:audit` using the same
`CATEGORY_LOGIC_*` environment variables.

## Host Prerequisites and Security

- The Ansible account and Kestra worker must use the same rootless Podman user and image storage.
- The worker container needs the Podman CLI and access to that user's Podman socket for the scheduled
  Kestra probe and for category batch launches.
- Restrict the socket and Ansible SSH key because Podman control is equivalent to code execution as
  that host user.
- Keep category containers short-lived. Long-running containers keep their original image until
  explicitly replaced; loading a newer image never mutates a running container.
- A worker may advertise the `onprem-orders` worker-group ID in addition to the reserved default
  subscriptions only when it is intended to execute that category.

The host may run unrelated web containers. Neither playbook calls `podman restart`, `podman rm`, or
Podman system-wide cleanup, so those containers remain untouched.

## Rollback

Keep the preceding immutable archive. Stage it with the same playbook and switch the Flow reference
back only after every host passes validation. Avoid deleting prior images until the rollback window
closes.

## Local Verification

`mise run kestra:category-logic:verify-local` creates two isolated Podman hosts, deploys logic
`1.0.0` and then `1.1.0`, proves an expected-version mismatch is rejected, audits both hosts,
executes the image-owned version task, and compares the worker marker container IDs and start
timestamps across both deployments. The test deliberately does not cover cold start.
