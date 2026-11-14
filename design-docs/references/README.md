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
| Kestra SSH Command | https://kestra.io/plugins/plugin-fs/ssh-secure-shell/io.kestra.plugin.fs.ssh.command | Certified task for executing commands on a remote machine and propagating exit status and output variables |
| Kestra SFTP Upload | https://kestra.io/plugins/plugin-fs/sftp-ssh-file-transfer-protocol/io.kestra.plugin.fs.sftp.upload | Certified task for copying a Kestra internal-storage file to an SSH-accessible worker |
| Kestra SFTP Download | https://kestra.io/plugins/plugin-fs/sftp-ssh-file-transfer-protocol/io.kestra.plugin.fs.sftp.download | Certified task for collecting a remote artifact into Kestra internal storage with checksum output |
| Kestra Namespace Files | https://kestra.io/docs/concepts/namespace-files | Official guidance for versioning Python sources in a namespace and resolving them as task inputs |
| Kestra File Access | https://kestra.io/docs/concepts/file-access | Official `nsfile:///` and `kestra:///` protocol reference |
| Kestra Shell Commands | https://kestra.io/plugins/plugin-script-shell/io.kestra.plugin.scripts.shell.commands | Official Shell Commands properties for Process execution, Namespace Files, inputs, outputs, and logs |
| Kestra Script Input And Output Files | https://kestra.io/docs/scripts/input-output-files | Official guidance for localizing task inputs and persisting generated artifacts in internal storage |
| Kestra Execution FILE Inputs | https://kestra.io/docs/workflow-components/execution#execute-a-flow-with-file-type-inputs | Official multipart FILE input contract; uploaded files become internal-storage objects available to tasks |
| Kestra Subflows | https://kestra.io/docs/workflow-components/subflows | Official reusable-flow composition and parent/child execution guidance |
| Kestra Loop | https://kestra.io/plugins/core/flow/io.kestra.plugin.core.flow.loop | Kestra 2.0 bounded-concurrency fan-out task using `item.value` iteration context |
| Kestra Retries | https://kestra.io/docs/workflow-components/retries | Official task-level retry strategies, attempts, duration, restart, and replay semantics |
| Kestra Dynamic Outputs | https://kestra.io/docs/workflow-components/outputs | Official dynamic task and flow output guidance |
| tacogips/kestra verified revision | https://github.com/tacogips/kestra/commit/6f6012b5e0d8f302b894d465672d8dda5222515f | Latest `main` revision resolved and built for the 2026-08-17 workerless GCE retry verification |
| Kestra Script Outputs And Metrics | https://kestra.io/docs/scripts/outputs-metrics | Official structured stdout marker format for variables and metrics |
| Kestra Flow Outputs | https://kestra.io/docs/workflow-components/outputs | Official typed flow outputs, Subflow output access, and conditional output guidance |
| Kestra Secrets | https://kestra.io/docs/concepts/secret | Official OSS `SECRET_` environment convention and `secret()` lookup guidance |
| Kestra upstream `GrpcConnectControllerService` | https://github.com/kestra-io/kestra/blob/17adacdad9c96463a1f5a376db5dd8debcfc553e/worker-controller/src/main/java/io/kestra/controller/grpc/services/GrpcConnectControllerService.java | Upstream OSS source showing `ConnectControllerService` and default OSS worker group resolution |
| Kestra upstream `WorkerQueueResolver` | https://github.com/kestra-io/kestra/blob/17adacdad9c96463a1f5a376db5dd8debcfc553e/worker-controller/src/main/java/io/kestra/controller/grpc/services/WorkerQueueResolver.java | Upstream OSS source showing default worker queue subscription behavior |
| Kestra upstream `worker_controller.proto` | https://github.com/kestra-io/kestra/blob/17adacdad9c96463a1f5a376db5dd8debcfc553e/worker-controller/src/main/proto/worker_controller.proto | Upstream OSS proto defining worker-initiated bidirectional job streaming |
| Kestra upstream `WorkerJobFetcher` | https://github.com/kestra-io/kestra/blob/17adacdad9c96463a1f5a376db5dd8debcfc553e/worker/src/main/java/io/kestra/worker/fetchers/WorkerJobFetcher.java | Upstream OSS worker-side source opening the worker job stream to the controller |
| tacogips Kestra OSS Worker Routing README | https://github.com/tacogips/kestra/blob/527a2078f4f59013a31b86747e736c0b00ed14fe/README.md#oss-worker-group-routing | Fork README section describing static OSS worker group routing and the ConnectController sequence |
| tacogips Kestra OSS Worker Routing design | https://github.com/tacogips/kestra/blob/527a2078f4f59013a31b86747e736c0b00ed14fe/docs/architecture/OSS_WORKER_ROUTING.md | Fork design note explaining static OSS worker routing, outbound worker connections, and limitations |
| tacogips Kestra Batch-Group Broadcast README | https://github.com/tacogips/kestra/blob/bf0e3240580448a80c4fc4850883d88c50e484a7/README.md#oss-worker-group-routing | Merged fork revision documenting broadcast as the default dispatch inside a selected Worker Queue |
| tacogips Kestra Broadcast Dispatch design | https://github.com/tacogips/kestra/blob/bf0e3240580448a80c4fc4850883d88c50e484a7/docs/architecture/OSS_WORKER_ROUTING.md#broadcast-dispatch | Merged fork design describing fan-out, result aggregation, output mapping, and limitations |
| GKE Pricing | https://cloud.google.com/kubernetes-engine/pricing | Official GKE cluster management, free tier, and compute billing model |
| GKE Cluster Autoscaler | https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler | Official GKE Standard cluster autoscaler behavior and node pool scaling guidance |
| GKE Autopilot Workload Separation | https://cloud.google.com/kubernetes-engine/docs/how-to/workload-separation | Official node selection, node affinity, and workload separation guidance for GKE Autopilot and Standard clusters |
| GKE Autopilot Troubleshooting | https://docs.cloud.google.com/kubernetes-engine/docs/troubleshooting/autopilot-clusters | Official Autopilot scale-to-zero and empty-cluster behavior notes |
| Kubernetes StatefulSets | https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/ | Official StatefulSet identity, scaling, and PVC retention behavior |
| Kubernetes StatefulSet Scaling | https://kubernetes.io/docs/tasks/run-application/scale-stateful-set/ | Official StatefulSet scale command and health caveats |
| GKE Persistent Volumes | https://docs.cloud.google.com/kubernetes-engine/docs/concepts/persistent-volumes | Official GKE persistent disk, PVC, and `standard-rwo` guidance |
| GKE Ingress Configuration | https://docs.cloud.google.com/kubernetes-engine/docs/how-to/ingress-configuration | Official BackendConfig and custom health-check behavior |
| Cloud Run Pricing | https://cloud.google.com/run/pricing | Official Cloud Run service and job billing examples |
| Cloud SQL Start and Stop | https://docs.cloud.google.com/sql/docs/postgres/start-stop-restart-instance | Official Cloud SQL PostgreSQL start, stop, and restart guidance |
| Apple container command reference | https://github.com/apple/container/blob/main/docs/command-reference.md | Apple container CLI command, network, and volume reference |
| pytest Documentation | https://docs.pytest.org/ | Python testing framework documentation |
| GitHub Actions Matrix Strategy | https://docs.github.com/en/actions/using-jobs/using-a-matrix-for-your-jobs | Official job matrix, dynamic `fromJSON` matrices, and `fail-fast` behavior |
| GitHub Actions Concurrency | https://docs.github.com/en/actions/using-jobs/using-concurrency | Official concurrency group and queueing semantics used for per-batch-group deploy isolation |
| GitHub Actions Environments | https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment | Official deployment environment, required reviewer, and environment secret guidance |
| GitHub Actions Security Hardening | https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions | Official guidance on action SHA pinning, minimal permissions, and untrusted-input handling |
| GitHub CODEOWNERS | https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners | Official per-directory ownership and required-review configuration |
| GitHub Tag Rulesets | https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets | Official ruleset guidance for restricting who may push tags matching a pattern |
| Kestra Namespaces | https://kestra.io/docs/concepts/namespace | Official hierarchical namespace, namespace-scoped secrets, KV, and plugin defaults guidance |
| Kestra Flow API | https://kestra.io/docs/api-reference/open-source | Official flow API reference including namespace-scoped bulk update and validation endpoints |
| GitFlow original post and 2020 reflection | https://nvie.com/posts/a-successful-git-branching-model/ | Vincent Driessen's 2010 git-flow model plus his 2020-03-05 note scoping it to versioned software and recommending GitHub flow for continuous delivery |
| DORA Trunk-Based Development | https://dora.dev/devops-capabilities/technical/trunk-based-development/ | DORA research capability page; elite performers 3.1x more likely to practice trunk-based development, fewer than three active branches, daily merges, no code freezes |
| Trunk Based Development: Branch For Release | https://trunkbaseddevelopment.com/branch-for-release/ | Canonical guidance that release branches are cut late and only on incompatible policy, and that fixes flow trunk to branch by cherry-pick, never branch to trunk |
| release-please | https://github.com/googleapis/release-please | Google tool generating per-component versions, changelogs, and tags from Conventional Commits; manifest mode with monorepo tags |
| release-please Manifest Releaser | https://github.com/googleapis/release-please/blob/main/docs/manifest-releaser.md | Manifest-driven configuration for independently released components in one repository |
| Monorepo With Independent Release Cycles | https://devblogs.microsoft.com/ise/streamlining-development-through-monorepo-with-independent-release-cycles/ | Microsoft ISE case study: per-project directories, manifest release-please, per-project deploy workflows keyed off per-component release outputs |
| Kestra deploy-action | https://github.com/kestra-io/deploy-action | Official deploy action; namespace, directory, resource, and server inputs, one namespace per call, `delete` defaulting to true |
| Kestra validate-action | https://github.com/kestra-io/validate-action | Official action for validating flows and namespace files before deployment |
| Martin Fowler: Feature Toggles | https://martinfowler.com/articles/feature-toggles.html | Canonical feature-flag taxonomy by lifetime and ownership, and the basis for decoupling deployment from release |
| Kargo Continuous Promotion | https://akuity.io/blog/how-kargo-fixes-gitops-with-promotion | GitOps promotion as a layer distinct from deployment, with immutable artifact snapshots promoted between stages |
| Nx Affected | https://nx.dev/ci/features/affected | Dependency-graph-based computation of which projects a change affects, the graph-based alternative to path filters |
| Kestra CI/CD | https://kestra.io/docs/version-control-cicd/cicd | Official guidance for deploying flows from a Git repository through CI, including namespace-scoped deployment |

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
