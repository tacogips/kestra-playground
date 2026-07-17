# OSS Worker Routing Sequence

This document explains the custom OSS Kestra fork's worker-routing mechanism with a Mermaid
sequence diagram.

## Overview

The OSS fork is a shared-backend routing model, not Kestra Enterprise Worker Groups. One GKE Kestra
controller observes the execution, while selected worker processes run tasks on GCE or
on-prem-style hosts. Routing happens before worker pickup: `workerSelector.tags` is mapped to a
static worker queue, and only workers with the matching `workerGroupId` receive jobs for that
queue over their worker-opened gRPC stream.

## Kestra Fork

This mechanism depends on the custom Kestra fork at
`https://github.com/tacogips/kestra/tree/bf0e3240580448a80c4fc4850883d88c50e484a7`.

The repository workflow checks out `tacogips/kestra` at the pinned broadcast-capable revision
`bf0e3240580448a80c4fc4850883d88c50e484a7`, builds
the custom Kestra executable, installs the GCS, shell, and Kubernetes plugins, and publishes the
result as:

```text
<region>-docker.pkg.dev/<project-id>/kestra-playground/kestra-oss-worker-routing:<tag>
```

The fork adds config-backed static worker routing for OSS deployments. In this repo's live routed
topology, the GKE controller config defines routing queues such as `gce-a` and `gce-b`, while each
external worker starts with `kestra.worker.routing.workerGroupId` set to the group it serves. The
worker process opens outbound gRPC to the WorkerController and advertises that group. When a task
declares `workerSelector.tags`, the fork maps those tags to the matching queue before dispatching
the job over a matching worker stream. That prevents ordinary load-balancing from sending
placement-sensitive work to the wrong worker.

Upstream `kestra/kestra` should not be used to verify this path. The static
`kestra.worker.routing` queue/group configuration only has routing semantics in the forked image,
and the live shared-backend database schema is tied to the custom `kestra-oss-worker-routing`
runtime image.

## Sequence

```mermaid
sequenceDiagram
    autonumber
    actor Operator
    participant API as GKE Kestra UI/API
    participant Exec as GKE Scheduler/Executor
    participant Router as OSS Routing Map
    participant DB as Shared Cloud SQL Queue
    participant WC as WorkerController gRPC
    participant Store as Shared GCS Storage
    participant CW as Controller Worker<br/>default/system
    participant WA as GCE Worker A<br/>workerGroupId=gce-a
    participant WB as GCE Worker B<br/>workerGroupId=gce-b

    WA->>WC: open streamWorkerJobs(workerGroupId=gce-a, permits)
    WC-->>WA: register stream for gce-a subscriptions
    WB->>WC: open streamWorkerJobs(workerGroupId=gce-b, permits)
    WC-->>WB: register stream for gce-b subscriptions

    Operator->>API: Start verify_gcp_worker_routing
    API->>DB: Persist execution and inputs
    Exec->>DB: Read execution and create task runs

    rect rgb(238, 247, 255)
        Exec->>Router: Resolve run_on_gce_a<br/>workerSelector.tags=[gce-a]
        Router-->>Exec: Route to worker queue gce-a
        Exec->>DB: Enqueue task run on gce-a queue
        DB-->>WC: keyed worker job available for gce-a
        WC-->>WA: dispatch run_on_gce_a on existing stream
        WA->>WA: Run Process task locally on GCE A
        WA->>Store: Write logs and internal artifacts
        WA->>WC: send completion/result
        WC->>DB: Mark task SUCCESS
        Exec->>DB: Observe task completion
    end

    rect rgb(245, 245, 245)
        Exec->>Router: Resolve run_on_gce_b<br/>workerSelector.tags=[gce-b]
        Router-->>Exec: Route to worker queue gce-b
        Exec->>DB: Enqueue task run on gce-b queue
        DB-->>WC: keyed worker job available for gce-b
        WC-->>WB: dispatch run_on_gce_b on existing stream
        WB->>WB: Run Process task locally on GCE B
        WB->>Store: Write logs and internal artifacts
        WB->>WC: send completion/result
        WC->>DB: Mark task SUCCESS
        Exec->>DB: Observe task completion
    end

    Exec->>DB: Mark execution SUCCESS
    API->>DB: Read execution, task runs, and states
    API->>Store: Read task logs/artifacts
    API-->>Operator: Show one execution with tasks run on selected workers
```

## Details

The controller-side routing configuration defines queue tags:

- `gce-a` maps to task selector tag `gce-a`.
- `gce-b` maps to task selector tag `gce-b`.

Each worker process starts with one group identity:

- GCE worker A uses `kestra.worker.routing.workerGroupId: gce-a`.
- GCE worker B uses `kestra.worker.routing.workerGroupId: gce-b`.
- The optional controller worker uses default/system queues for lightweight unrouted control work.

Workers do not directly poll the Kestra database for worker jobs. Each worker opens an outbound
`WorkerControllerService.streamWorkerJobs` gRPC stream, sends its worker group and capacity, and
the WorkerController registers that stream against the resolved queue subscriptions. Jobs and
events are sent back over that same stream.

In the sequence diagram, `dispatch ... on existing stream` means the worker has already established
an application-level subscription through the WorkerController. It does not mean the controller
opens a new connection to the worker, and it does not mean the worker is a direct database queue
subscriber.

A routed task uses this shape:

```yaml
workerSelector:
  tags: [gce-a]
  match: ALL
  fallback: FAIL
taskRunner:
  type: io.kestra.plugin.core.runner.Process
```

`fallback: FAIL` is important for placement-sensitive work: if the selector cannot be satisfied,
the task should fail instead of silently running on a default worker. `Process` is also important
for shell tasks because it runs the command inside the selected worker container or host. Without
that explicit task runner, script plugin defaults can try Docker execution and fail when the worker
does not mount a Docker socket.

## References

- `design-docs/specs/architecture.md`
- `design-docs/specs/command.md`
- `https://github.com/tacogips/kestra/tree/bf0e3240580448a80c4fc4850883d88c50e484a7`
- `kestra/flows-worker-routing/verify_gcp_worker_routing.yaml`
- `k8s/base/configmap.yaml`
