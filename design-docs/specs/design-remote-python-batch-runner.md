# Remote Python Batch Runner

This document defines reusable Kestra patterns for localizing a Python batch program onto a selected
execution machine, running it there, and retaining controller-visible state, logs, outputs, and
errors. It distinguishes unmanaged SSH machines from machines already participating as routed
Kestra workers.

## Requirements

- Provide realistic database-export and log-parsing Python examples.
- Copy the selected source for every execution instead of assuming it is baked into a worker image.
- Keep transport and orchestration mechanics out of individual business flows.
- Expose progress, stdout/stderr, exit status, structured values, artifacts, and failures in Kestra.
- Support unmanaged machines through SSH/SFTP.
- Support routed GKE/on-prem-style workers without SSH/SFTP; the batch runtime requires only `uv`
  and a compatible Python, which `uv` may provision.

## Adapter Selection

There is no protocol-free remote execution. A passive destination cannot receive code or a start
command with only Python installed; a transport or resident control plane must exist. Use the
adapter matching the machine's existing control channel:

| Destination | Control channel | Batch-side runtime | Source and result transport |
|-------------|-----------------|--------------------|-----------------------------|
| Unmanaged machine | OpenSSH server | Python 3 | SFTP over SSH |
| Routed GKE/on-prem-style worker | Kestra worker outbound gRPC stream | `uv`; Python may be provisioned by `uv` | Execution FILE input and Kestra internal storage |
| Kubernetes child pod | Kubernetes API and kubelet | Python/uv container | Pod task input/output files |

An unmanaged machine with neither SSH, a Kestra worker, Kubernetes, nor an equivalent agent cannot
be started remotely. That is a control-plane constraint, not a Python packaging issue.

## Shared Batch Program Contract

Each copied program is standalone and uses the same small interface under either adapter:

| Input | Meaning |
|-------|---------|
| `KESTRA_BATCH_CONFIG` | JSON object containing business parameters. |
| `KESTRA_BATCH_OUTPUT` | Artifact destination: absolute on SSH, task-relative on routed workers. |
| stdout | Human-readable progress plus compact Kestra output/metric markers. |
| stderr | Actionable error text. |
| exit `0` | Success; the framework persists the artifact. |
| non-zero exit | Failure; Kestra marks the execution task and parent execution failed. |

The SSH runner base64-encodes JSON while rendering the remote command and decodes it on the machine.
The routed runner passes JSON through the task environment, avoiding shell evaluation. Both example
programs write artifacts atomically through a temporary file and use only the Python standard
library.

## SSH/SFTP Adapter

`playground.remote_batch.remote_batch_runner` is a reusable Subflow. A business flow supplies only
the Namespace File name, JSON configuration, artifact name, and worker connection coordinates.

The runner performs six controller-visible stages:

1. `resolve_source` converts a versioned Namespace File into a Kestra internal-storage URI.
2. `prepare_workspace` creates an execution-scoped directory on the remote worker over SSH.
3. `stage_source` copies the resolved Python file into that directory over SFTP.
4. `execute_batch` invokes `python3 main.py` over SSH and streams stdout/stderr to Kestra logs.
5. `collect_artifact` downloads the result into internal storage and returns its SHA-256 checksum.
6. `cleanup_workspace` removes the execution-scoped remote directory.

A flow-level error handler cleans a failed workspace. The original execution remains failed, so the
caller receives the failure through `transmitFailed: true`.

### File Transfer And Result Management

The implementation does not invoke the `scp` command. Kestra's SFTP tasks use the SFTP subsystem
over the same SSH transport used by the command tasks:

```text
repository
  -> Kestra Namespace Files API during registration
  -> Namespace File in internal storage
  -> DownloadFiles resolves an internal-storage URI
  -> SFTP Upload copies source to <execution-id>/main.py
  -> SSH Command runs python3 main.py and captures stdout/stderr/exit status
  -> SFTP Download copies the artifact into internal storage and returns its checksum
  -> SSH Command removes the execution directory
```

The destination needs `sshd` with its SFTP subsystem enabled, a reachable port, an authenticated
account, and filesystem permissions. `openssh-server` normally provides both `sshd` and
`internal-sftp`/`sftp-server`; no `scp` binary, SFTP client, or Kestra agent is needed there.

Kestra owns the result in four forms:

- the SSH process exit code determines task success or failure;
- flushed stdout/stderr becomes execution logs;
- `::{"outputs":...,"metrics":...}::` records become task variables and metrics;
- SFTP Download persists the artifact and exposes its internal URI and SHA-256 checksum.

## Routed Worker Adapter

`playground.remote_batch.routed_batch_runner` is the adapter for the
`fix/gke-scale-to-zero` topology. It contains one Shell `Commands` task with a Process task runner:

1. `workerSelector.tags` queues the task for `gke-small` or `gke-large`.
2. The activator wakes the fixed routed-worker set from zero replicas after user access.
3. The selected worker receives the task through its outbound controller gRPC stream.
4. The caller uploads a `tar.gz` as a FILE input; Kestra stores it under a `kestra:///` URI.
5. `inputFiles` localizes that exact internal-storage object without listing Namespace Files.
6. `uv` provisions Python, extracts the bundle, and runs the business entry point locally.
7. stdout/stderr, exit status, and structured output markers return through the task protocol.
8. `outputFiles` uploads the artifact to internal storage; the framework emits its checksum.
9. An `EXIT` trap removes the bundle, extracted source, uv cache, and uv-managed Python on success or
   failure, checks that none of those paths still exists, and only then emits `verified=true`;
   Kestra then removes the temporary task directory.
10. The activator later parks the worker.

```text
user -> activator -> wake routed workers
controller -> workerSelector -> selected Kestra worker
execution FILE upload -> internal storage -> inputFiles -> task working directory
uv -> Python batch -> stdout/stderr/exit status
task working directory -> outputFiles -> internal storage
idle reaper -> routed workers return to zero
```

This path deliberately does not install or expose `sshd`. The generic Kestra worker is the resident
control channel; the business execution environment needs only `uv` and Python. If Python is absent,
`uv` can provision the requested interpreter, subject to worker network/cache policy. Production
images should pre-provision the interpreter or persist the uv cache when cold-start latency or
offline execution matters.

For the strict ephemeral mode implemented here, `UV_CACHE_DIR` and `UV_PYTHON_INSTALL_DIR` both
point below the Kestra task working directory. The shell `EXIT` trap deletes those directories and
the localized bundle/`source_root` after either a zero or non-zero Python exit. It tests every path
after deletion; a cleanup failure converts an otherwise successful task into a failure, while a
business failure keeps its original non-zero status. The declared output file is left long enough
for `outputFiles` to persist it, after which Kestra deletes the remaining working directory. A
pod-level hard kill can bypass a shell trap, but the working directory is on the routed worker's
ephemeral volume and disappears with the worker pod.

The deployed custom routing fork does not implement
`NamespaceFileMetadataService/findAll` on the worker-controller gRPC endpoint. Therefore a routed
worker must not use `namespaceFiles.include`, which requires a remote metadata listing. The FILE
upload is resolved to a concrete `kestra:///` object by the controller and is safe to localize with
`inputFiles` on the routed worker.

## Examples And Addition Boundary

`batches/db_export/export_database.py` opens SQLite read-only, permits only `SELECT`/`WITH`, writes
CSV, logs row progress, and emits row-count variables and metrics.

`batches/log_parse/parse_logs.py` reads JSON Lines logs, filters by business date, counts levels and
services, records malformed lines, writes a JSON summary, and emits line/error variables and
metrics.

Each caller is a one-task Subflow wrapper. A new SSH batch adds its Python source plus a caller with
connection inputs. A new routed batch adds its source directory plus a caller specifying
`batch_bundle`, `source_root`, `script_name`, business `config_json`, `output_file`, and
`worker_group`. `scripts/build-remote-batch-bundles.sh` provides the repeatable bundle layout.
Neither caller repeats transfer, execution, artifact, checksum, cleanup, or failure logic.

## Progress And Error Semantics

The scripts emit `progress phase=...` lines and structured `::...::` markers. Both adapters expose
them under Kestra execution logs and task variables. A non-zero process exit fails the runner
execution and its caller. Artifacts are uploaded only after successful execution.

The SSH graph exposes prepare, upload, execution, download, and cleanup as separate task states. The
routed graph exposes one atomic selected-worker task; execution FILE localization and output-file
persistence are lifecycle phases of that task.

## Security And Production Boundaries

- SSH passwords or keys must resolve through Kestra Secrets. The committed password is local-only.
- Production SSH targets must verify host identity and use a least-privilege account.
- Restrict inbound SSH to the Kestra workers that execute the adapter tasks.
- Routed workers should not gain an inbound SSH port merely for source copy; keep their controller
  stream outbound and use execution FILE `inputFiles`/`outputFiles`.
- Business paths and output names belong to trusted flow authors, not untrusted callers.
- The current adapters collect one declared artifact. Extend the framework explicitly for bounded
  multi-artifact batches.

## Verification Evidence

Local Docker verification on 2026-07-13 used Kestra `1.3.24` and File System plugin `2.10.2`.

| Scenario | Parent execution | Runner execution | Evidence |
|----------|------------------|------------------|----------|
| SQLite export | `T3Wksz8ugIv0r7gcaGYxj` | `tROeLH4b0KcyhLQ90v9gr` | Six SSH/SFTP stages succeeded; 3 CSV rows; cleanup verified; destination scan empty. |
| JSONL parse | `5D4NRFjQVMr8Ac98KJ6vEe` | `6XLDH659FyCySBLNKVRv1Y` | Six stages succeeded; 3 matches, 1 malformed; cleanup verified; destination scan empty. |
| Missing log | `5SiYk5YQ3h5usHNaY3Wm69` | `3E4No3T5vnjjiwZSSl4bPQ` | Caller failed as expected; error cleanup verified; destination scan empty. |

Live GKE verification on 2026-07-13 used the full-parking `fix/gke-scale-to-zero` topology with
`gke-small`, `gke-large`, webserver, executor, scheduler, and indexer initially and finally at zero
replicas.

| Scenario | Parent execution | Runner execution | Evidence |
|----------|------------------|------------------|----------|
| Routed SQLite export | `5j7sL3tbIDEc3bmqDdZbir` | `2xVMqy5OqujuXAUEFUEKDm` | `gke-small`; 3 rows; artifact/checksum; all runtime paths verified absent. |
| Routed JSONL parse | `2oC6pDl9NszxdB44ZrYAlZ` | `1UNLWWW8Bo7gcyw5iHujxc` | `gke-large`; 3 matches, 1 malformed; all runtime paths verified absent. |
| Routed missing log | `5ffTMRIUlLfoq7reU7z4RA` | `3gL0SlobVApt0wwzQE3Tgb` | Expected failure preserved; all runtime paths verified absent. |

The local verifier is `scripts/verify-local-remote-batch.sh`. The cold GKE routed verifier is
`scripts/verify-live-remote-batch-routed.sh`.

## References

See `design-docs/references/README.md`.
