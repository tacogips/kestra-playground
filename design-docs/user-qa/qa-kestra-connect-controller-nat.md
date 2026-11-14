# Kestra ConnectController gRPC And On-Prem NAT

**Status**: Answered

**Created**: 2026-06-30

**Category**: Architecture Investigation

## Question

In `https://github.com/tacogips/kestra/`, the README sequence shows the worker process communicating with `ConnectController gRPC`.

Is this `ConnectController` feature available in the OSS version? If a worker is placed in an on-prem environment, it will access `onprem worker -> connect controller` over gRPC. If the on-prem environment uses NAT, can this work without issues?

## Answer

`ConnectControllerService` / `ConnectController gRPC` exists in upstream Kestra OSS. The worker calls it during startup, and the controller returns the resolved worker group plus worker configuration.

However, upstream OSS does not provide full worker-group routing through this path. The OSS implementation resolves every worker to the default worker group, and the default queue resolver always returns the default queue subscription. Upstream Enterprise overrides this behavior for real Worker Group resolution.

The `tacogips/kestra` README describes a fork-specific feature: static, configuration-backed worker group routing for OSS deployments. That fork adds behavior where the worker advertises its configured `workerGroupId`, the controller returns the resolved group, and the worker controller maps that group to configured queue subscriptions.

Summary:

| Capability | Upstream OSS | `tacogips/kestra` fork | Upstream Enterprise |
|------------|--------------|------------------------|---------------------|
| `ConnectController gRPC` service | Yes | Yes | Yes |
| Worker startup connects to controller over gRPC | Yes | Yes | Yes |
| Worker group resolves to non-default group | No, default only | Yes, static config-backed | Yes, Enterprise Worker Groups |
| UI/repository-backed Worker Group management | No | No | Yes |

## NAT And Network Implications

This should generally work behind normal outbound NAT because the connection direction is from the on-prem worker to the controller gRPC endpoint. The fork documentation states that no controller-to-worker SSH or HTTP callback is involved; workers connect outbound to the controller and backend, then consume queues assigned to their resolved group.

For a closed on-prem data center, the important boundary is:

- GCP/controller does not initiate requests to the on-prem worker.
- The on-prem worker initiates outbound gRPC connections to the controller.
- The on-prem worker may also need outbound access to the configured backend dependencies it uses, such as database, storage, secret manager, container registry, package repositories, or task-specific external services.
- No inbound NAT, port forwarding, public worker endpoint, or GCP-to-on-prem firewall opening should be required for the worker dispatch path itself.

Operational requirements:

- The on-prem worker must be able to open outbound TCP connections to the controller gRPC endpoint and port.
- The controller endpoint discovered by the worker must be reachable from on-prem. Avoid cloud-internal-only IPs unless the on-prem network has VPN, private link, or equivalent routing.
- NAT gateways, firewalls, and proxies must allow long-lived HTTP/2 gRPC streams. Short idle timeouts can cause reconnects.
- Upstream OSS defaults to plaintext/insecure gRPC transport, while Enterprise overrides can add TLS. For on-prem over untrusted networks, protect the connection with VPN, private networking, tunnel, load balancer TLS, or equivalent controls.
- The fork's OSS routing layer does not add runtime authorization. Controller gRPC, database, storage, and secrets still need network and secret-management protection.

## Worker Controller Placement

In an on-prem worker model, the worker controller can run in GCP as long as the on-prem worker can initiate outbound gRPC to it.

The worker job dispatch path uses `WorkerControllerService.streamWorkerJobs`, a bidirectional streaming RPC. The worker opens the stream to the worker controller, sends its initial `WorkerConnectionInfo`, permits, and acknowledgements, and the controller sends jobs and events back on that same worker-initiated stream.

Therefore:

- The worker controller does not need to initiate a separate network request to the on-prem worker process.
- GCP does not need inbound access into the closed on-prem data center for this dispatch path.
- The on-prem side still needs outbound access to the GCP worker controller gRPC endpoint.
- If the outbound stream is interrupted by NAT, firewall, proxy, or load balancer behavior, the worker must reconnect and jobs will only dispatch while a matching worker stream is connected.

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
  -> dispatches matching jobs/events back on the same stream
```

So the precise wording is not that the worker subscribes to the worker controller as a queue client. The worker connects to the worker controller; the worker controller registers that worker stream against the configured queue subscriptions and pushes work over the existing stream when the worker has capacity.

In a JDBC-backed OSS deployment, the database may still be part of Kestra's backend queue/state implementation, and workers may need backend access for other runtime functions depending on configuration. The worker dispatch path itself is not an on-prem worker repeatedly querying the database for work.

When a sequence says the worker controller dispatches a job to the worker, interpret it as a
message sent on the already-open worker stream. The worker has effectively subscribed at the
application level by opening `streamWorkerJobs`, advertising its worker group/capacity, and letting
the WorkerController register that stream against queue subscriptions. It is not a new inbound
GCP-to-on-prem request, and it is not the worker directly subscribing to the database queue.

## References

See:

- `design-docs/specs/design-onprem-worker-model.md`
- `design-docs/references/README.md`
