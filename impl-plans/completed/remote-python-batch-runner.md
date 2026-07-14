# Remote Python Batch Runner Plan

**Status**: COMPLETE  
**Design**: `design-docs/specs/design-remote-python-batch-runner.md`  
**Started**: 2026-07-13  
**Completed**: 2026-07-13

## Scope

Create reusable adapters that copy Python source to an unmanaged SSH machine or a routed
scale-from-zero worker, execute it under Kestra control, capture progress/errors/artifacts, remove
execution-scoped runtime files, and demonstrate both paths with database export and log parsing.

## Workstreams

| Workstream | Deliverables | Status | Validation |
|------------|--------------|--------|------------|
| Research and design | Design doc and reference index | COMPLETE | Primary Kestra sources recorded |
| Shared framework | `kestra/flows-remote-batch/00_remote_batch_runner.yaml` | COMPLETE | Registered and executed locally |
| Routed framework | `kestra/flows-remote-batch/01_routed_batch_runner.yaml` | COMPLETE | Both static GKE worker groups verified live |
| Batch examples | `batches/db_export/`, `batches/log_parse/`, SSH and routed caller flows | COMPLETE | Unit and live success checks |
| Local worker | `local/docker/remote-worker/`, Compose wiring | COMPLETE | Healthy SSH/SFTP worker container |
| Bundle and cleanup | `scripts/build-remote-batch-bundles.sh`, routed EXIT trap | COMPLETE | Success/failure path absence checks verified |
| Verification | Local and GKE verifier scripts | COMPLETE | Two successes and one expected failure per adapter |
| Operations docs | Command runbook, notes, references | COMPLETE | Repeatable commands documented |

## Dependencies

- SSH adapter: compatible `plugin-fs`, worker-to-machine network access, OpenSSH/SFTP, Python 3, and
  the named Kestra credential secret.
- Routed adapter: custom static worker routing, the scale-from-zero activator topology, and `uv` on
  the routed worker image.
- Routed source upload: Kestra FILE input/internal storage; Namespace File metadata listing is not
  supported by the deployed worker-controller gRPC endpoint.

## Completion Criteria

- [x] Two realistic Python batch programs exist and have tests.
- [x] Caller flows contain no SSH/SFTP execution boilerplate.
- [x] Source is copied to the remote machine for every execution.
- [x] Progress, structured variables, artifacts, checksums, and failures are visible in Kestra.
- [x] The success path is verified for both examples.
- [x] The remote error path and cleanup are verified.
- [x] Routed success and failure remove the bundle, extracted source, uv cache, and managed Python.
- [x] Cold wake-up and final scale-to-zero are verified on `fix/gke-scale-to-zero`.
- [x] Primary web research sources and operating commands are documented.

## Progress Log

### Session: 2026-07-13

**Tasks Completed**: Researched official Kestra SSH/SFTP, Namespace File, Subflow, output, and secret
contracts; implemented the shared runner, worker fixture image, examples, tests, registration, and
verification; corrected Namespace File-to-internal-storage resolution and non-recursive variable
rendering discovered during live runs; verified two successes and one expected failure.

Extended the framework for the latest GKE topology with a static worker-group Switch, execution FILE
bundles, uv-only runtime provisioning, success/failure cleanup, activator heartbeat handling, and
transient API retries. Verified both routed worker groups, expected failure propagation, and the
return of all six managed Deployments to zero replicas. Strengthened both cleanup paths so markers
are emitted only after checking that runtime paths are absent; the local verifier also scans the
destination directly after each execution. Re-ran the local SSH/SFTP regression after the routed
changes.

**Blockers**: None.
