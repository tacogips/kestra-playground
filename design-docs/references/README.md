# Design References

This directory contains reference materials for system design and implementation.

## External References

| Name | URL | Description |
|------|-----|-------------|
| Python Documentation | https://docs.python.org/3/ | Official Python language and standard library documentation |
| Python Packaging User Guide | https://packaging.python.org/ | Python packaging standards and project configuration guidance |
| uv Documentation | https://docs.astral.sh/uv/ | uv package and project management documentation |
| Ruff Documentation | https://docs.astral.sh/ruff/ | Python linting and formatting documentation |
| ty Documentation | https://docs.astral.sh/ty/ | Python type checker documentation |
| Kestra Docker Compose | https://kestra.io/docs/installation/docker-compose | Official Kestra Docker Compose setup with PostgreSQL and multi-component examples |
| Kestra Configuration | https://kestra.io/docs/configuration | Official Kestra runtime configuration entry point |
| Kestra Kubernetes | https://kestra.io/docs/installation/kubernetes | Official Kestra Helm/Kubernetes deployment and scaling guidance |
| Kestra GCP GKE | https://kestra.io/docs/installation/kubernetes-gcp-gke | Official GKE, Cloud SQL, and GCS deployment guidance |
| Kestra Server Components | https://kestra.io/docs/architecture/server-components | Official description of Kestra webserver, scheduler, executor, indexer, worker, and Worker Group responsibilities |
| Kestra Deployment Architecture | https://kestra.io/docs/architecture/deployment-architecture | Official JDBC and Kafka deployment architecture guidance, including component communication and HA dependencies |
| Kestra Worker Groups | https://kestra.io/docs/enterprise/scalability/worker-group | Official Enterprise Worker Group routing guidance for dedicated and distant workers |
| Kestra Enterprise Authentication | https://kestra.io/docs/enterprise/auth/authentication | Official Enterprise Basic Auth, OIDC, and JWT secret configuration guidance |
| Kestra Cloud Run Task Runner | https://kestra.io/docs/task-runners/types/google-cloudrun-task-runner | Official Kestra guidance for running tasks as serverless containers on Cloud Run |
| Kestra Task Runners vs Worker Groups | https://kestra.io/docs/task-runners/task-runners-vs-worker-groups | Official Kestra comparison of ephemeral task runners and always-on worker groups |
| Kestra Process Task Runner | https://kestra.io/docs/task-runners/types/process-task-runner | Official guidance for local process execution on specific worker hosts, including GPU-oriented examples |
| Kestra upstream `GrpcConnectControllerService` | https://github.com/kestra-io/kestra/blob/17adacdad9c96463a1f5a376db5dd8debcfc553e/worker-controller/src/main/java/io/kestra/controller/grpc/services/GrpcConnectControllerService.java | Upstream OSS source showing `ConnectControllerService` and default OSS worker group resolution |
| Kestra upstream `WorkerQueueResolver` | https://github.com/kestra-io/kestra/blob/17adacdad9c96463a1f5a376db5dd8debcfc553e/worker-controller/src/main/java/io/kestra/controller/grpc/services/WorkerQueueResolver.java | Upstream OSS source showing default worker queue subscription behavior |
| Kestra upstream `worker_controller.proto` | https://github.com/kestra-io/kestra/blob/17adacdad9c96463a1f5a376db5dd8debcfc553e/worker-controller/src/main/proto/worker_controller.proto | Upstream OSS proto defining worker-initiated bidirectional job streaming |
| Kestra upstream `WorkerJobFetcher` | https://github.com/kestra-io/kestra/blob/17adacdad9c96463a1f5a376db5dd8debcfc553e/worker/src/main/java/io/kestra/worker/fetchers/WorkerJobFetcher.java | Upstream OSS worker-side source opening the worker job stream to the controller |
| tacogips Kestra OSS Worker Routing README | https://github.com/tacogips/kestra/blob/527a2078f4f59013a31b86747e736c0b00ed14fe/README.md#oss-worker-group-routing | Fork README section describing static OSS worker group routing and the ConnectController sequence |
| tacogips Kestra OSS Worker Routing design | https://github.com/tacogips/kestra/blob/527a2078f4f59013a31b86747e736c0b00ed14fe/docs/architecture/OSS_WORKER_ROUTING.md | Fork design note explaining static OSS worker routing, outbound worker connections, and limitations |
| GKE Pricing | https://cloud.google.com/kubernetes-engine/pricing | Official GKE cluster management, free tier, and compute billing model |
| GKE Cluster Autoscaler | https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler | Official GKE Standard cluster autoscaler behavior and node pool scaling guidance |
| GKE Autopilot Workload Separation | https://cloud.google.com/kubernetes-engine/docs/how-to/workload-separation | Official node selection, node affinity, and workload separation guidance for GKE Autopilot and Standard clusters |
| GKE Autopilot Troubleshooting | https://docs.cloud.google.com/kubernetes-engine/docs/troubleshooting/autopilot-clusters | Official Autopilot scale-to-zero and empty-cluster behavior notes |
| Cloud Run Pricing | https://cloud.google.com/run/pricing | Official Cloud Run service and job billing examples |
| Cloud SQL Start and Stop | https://docs.cloud.google.com/sql/docs/postgres/start-stop-restart-instance | Official Cloud SQL PostgreSQL start, stop, and restart guidance |
| Apple container command reference | https://github.com/apple/container/blob/main/docs/command-reference.md | Apple container CLI command, network, and volume reference |
| pytest Documentation | https://docs.pytest.org/ | Python testing framework documentation |

## Reference Documents

Reference documents should be organized by topic:

```
references/
├── README.md              # This index file
├── python/                # Python patterns and practices
└── <topic>/               # Other topic-specific references
```

## Adding References

When adding new reference materials:

1. Create a topic directory if it does not exist
2. Add reference documents with clear naming
3. Update this README.md with the reference entry
