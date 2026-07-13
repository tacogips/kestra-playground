# On-Prem Worker Model

This document explains the network and job-dispatch model for running Kestra worker processes in a
closed on-prem data center while the Kestra controller-side components run in GCP.

## Overview

The on-prem worker model is outbound-only from the data center for the worker dispatch path. GCP
does not need to initiate a network request to the on-prem worker process.

The important direction is:

```text
on-prem worker process
  -> outbound gRPC
  -> GCP WorkerController / controller gRPC endpoint
```

The worker controller can run in GCP as long as the on-prem worker can open and maintain outbound
HTTP/2 gRPC connectivity to it.

## Job Acquisition Model

The worker process does not directly poll Kestra's database for worker jobs.

The model is:

```text
Worker process
  -> opens outbound gRPC stream to WorkerController
  -> advertises worker id, worker group id, max concurrency, and available permits

WorkerController
  -> resolves the worker group to queue subscriptions
  -> registers the worker stream for those queues
  -> dispatches matching jobs/events back on the same worker-opened stream
```

The precise wording is that the worker connects to the worker controller; the worker controller
registers that worker stream against queue subscriptions. The worker is not a direct database queue
client that repeatedly queries Kestra's DB for worker jobs.

## Dispatch Job Semantics

When the upstream or fork sequence says the controller dispatches a job to the worker, interpret it
as a message sent on an already-open worker stream.

The worker-side behavior is close to an application-level subscription:

- the worker opens outbound `streamWorkerJobs` gRPC to the WorkerController;
- the worker advertises its `workerGroupId`, capacity, and available permits;
- the WorkerController resolves that group to queue subscriptions;
- the WorkerController registers the worker stream for those queues;
- when a matching job exists and the worker has capacity, the WorkerController sends a
  `WorkerJobResponse` on that existing stream.

This is not a new inbound request from GCP to the on-prem worker. It is also not the worker directly
subscribing to or polling the database queue. The subscription is mediated by the WorkerController
and carried over the worker-initiated gRPC stream.

## Network Boundary

For a closed on-prem data center:

- GCP/controller does not initiate requests to the on-prem worker.
- The on-prem worker initiates outbound gRPC to the controller and worker controller endpoint.
- No inbound NAT, public worker endpoint, port forwarding, or GCP-to-on-prem firewall opening is
  required for the worker dispatch path itself.
- NAT gateways, firewalls, proxies, and load balancers must allow long-lived HTTP/2 gRPC streams.
- If the outbound stream is interrupted, the worker must reconnect before new matching jobs can be
  dispatched to it.

## Backend Access

The dispatch path itself is not "worker polls Kestra DB for work." However, the worker may still
need outbound access to backend dependencies depending on the runtime configuration and task types:

- controller gRPC / worker controller gRPC endpoint;
- Kestra internal storage, such as GCS, if worker tasks read or write internal files directly;
- container registry or package repositories used by task execution;
- secret manager or other secret sources configured for the worker;
- task-specific systems, such as the business database or on-prem/private services.

Do not assume the worker can be fully network-isolated except for a single gRPC endpoint until the
selected Kestra configuration, task runners, plugins, and secret/storage paths are verified.

## Security Notes

The custom OSS worker-routing layer is static routing, not full Enterprise Worker Groups. It does
not add runtime authorization by itself. Protect the controller gRPC endpoint, backend credentials,
and worker configuration through private networking, VPN/private link/tunnel, TLS termination,
firewall rules, and secret-management controls appropriate to the deployment.

## References

- `design-docs/specs/design-oss-worker-routing-sequence.md`
- `design-docs/user-qa/qa-kestra-connect-controller-nat.md`
- `design-docs/references/README.md`
