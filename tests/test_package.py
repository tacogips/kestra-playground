import datetime
import os
import subprocess
from pathlib import Path
from typing import Any

import yaml

from kestra_playground import greet


def test_greet_returns_expected_message() -> None:
    assert greet("uv") == "Hello, uv!"


def test_ecommerce_fixture_sql_is_embedded_in_generator_flow() -> None:
    flow = "kestra/flows/generate_ecommerce_mock_data.yaml"

    assert _flow_task_sql(flow, "seed_dimensions") == _read_text(
        "kestra/fixtures/ecommerce/seed_dimensions.sql"
    )
    assert _flow_tasks_sql(
        flow,
        [
            "purge_daily_facts",
            "insert_orders_and_items",
            "insert_payments",
            "insert_inventory_snapshots",
            "insert_support_tickets",
        ],
    ) == _read_text("kestra/fixtures/ecommerce/generate_daily_facts.sql")


def test_customer_segments_fixture_sql_is_embedded_in_batch_flow() -> None:
    assert _flow_tasks_sql(
        "kestra/flows/build_ecommerce_customer_segments.yaml",
        [
            "ensure_customer_segments_table",
            "purge_customer_segments",
            "write_customer_segments",
        ],
    ) == _read_text("kestra/fixtures/ecommerce/build_customer_segments.sql")


def test_batch_flows_are_split_into_granular_otel_audit_tasks() -> None:
    assert _flow_task_ids("kestra/flows/generate_ecommerce_mock_data.yaml") == [
        "create_tables",
        "seed_dimensions",
        "purge_daily_facts",
        "insert_orders_and_items",
        "insert_payments",
        "insert_inventory_snapshots",
        "insert_support_tickets",
        "summarize_generated_data",
    ]
    assert _flow_task_ids("kestra/flows/build_ecommerce_daily_report.yaml") == [
        "ensure_report_table",
        "purge_report",
        "write_sales_summary",
        "write_order_status_summary",
        "write_channel_summary",
        "write_inventory_summary",
        "write_support_summary",
        "fetch_report",
    ]
    assert _flow_task_ids("kestra/flows/build_ecommerce_customer_segments.yaml") == [
        "ensure_customer_segments_table",
        "purge_customer_segments",
        "write_customer_segments",
        "fetch_segment_summary",
    ]


def test_k8s_kestra_config_exports_otel_to_collector() -> None:
    configmap = _yaml_document(
        "k8s/base/configmap.yaml", kind="ConfigMap", name="kestra-runtime-config"
    )
    app_config = yaml.safe_load(configmap["data"]["application.yaml"])

    assert app_config["micronaut"]["otel"]["enabled"] == "${OTEL_ENABLED:true}"
    assert app_config["otel"]["traces"]["exporter"] == "${OTEL_TRACES_EXPORTER:otlp}"
    assert app_config["otel"]["metrics"]["exporter"] == "${OTEL_METRICS_EXPORTER:otlp}"
    assert app_config["otel"]["logs"]["exporter"] == "${OTEL_LOGS_EXPORTER:otlp}"
    assert app_config["otel"]["exporter"]["otlp"]["endpoint"] == "${OTEL_EXPORTER_OTLP_ENDPOINT}"
    assert app_config["kestra"]["traces"]["root"] == "${KESTRA_TRACES_ROOT:DEFAULT}"


def test_k8s_otel_collector_receives_and_exports_all_signals() -> None:
    kustomization = _yaml_load("k8s/base/kustomization.yaml")
    configmap = _yaml_document(
        "k8s/base/otel-collector.yaml", kind="ConfigMap", name="otel-collector-config"
    )
    service = _yaml_document("k8s/base/otel-collector.yaml", kind="Service", name="otel-collector")
    collector_config = yaml.safe_load(configmap["data"]["config.yaml"])

    assert "otel-collector.yaml" in kustomization["resources"]
    assert collector_config["receivers"]["otlp"]["protocols"]["grpc"]["endpoint"] == "0.0.0.0:4317"
    assert collector_config["receivers"]["otlp"]["protocols"]["http"]["endpoint"] == "0.0.0.0:4318"
    assert collector_config["service"]["pipelines"]["traces"]["exporters"] == ["debug"]
    assert collector_config["service"]["pipelines"]["metrics"]["exporters"] == ["debug"]
    assert collector_config["service"]["pipelines"]["logs"]["exporters"] == ["debug"]
    assert {port["port"] for port in service["spec"]["ports"]} == {4317, 4318, 13133}


def test_k8s_helm_values_define_split_components_and_worker_hpa() -> None:
    kustomization = _yaml_load("k8s/base/kustomization.yaml")
    helm_values = _yaml_load("k8s/helm/kestra-values.yaml")
    controller_only_values = _yaml_load("k8s/helm/kestra-controller-only-values.yaml")
    deployments = helm_values["deployments"]
    common_env = {
        item["name"]: item["value"] for item in helm_values["common"]["extraEnv"] if "value" in item
    }

    assert "webserver.yaml" not in kustomization["resources"]
    assert "executor.yaml" not in kustomization["resources"]
    assert "scheduler.yaml" not in kustomization["resources"]
    assert "indexer.yaml" not in kustomization["resources"]
    assert "worker.yaml" not in kustomization["resources"]
    assert "hpa.yaml" not in kustomization["resources"]

    for component in ("webserver", "executor", "scheduler", "indexer", "worker"):
        deployment = deployments[component]
        env = {item["name"]: item["value"] for item in deployment["extraEnv"]}

        assert deployment["enabled"] is True
        assert env["OTEL_SERVICE_NAME"] == f"kestra-{component}"
        assert f"kestra.component={component}" in env["OTEL_RESOURCE_ATTRIBUTES"]

    assert common_env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://otel-collector:4317"
    assert helm_values["configurations"]["configmaps"] == [
        {"name": "kestra-runtime-config", "key": "application.yaml"}
    ]
    assert {"secretRef": {"name": "kestra-secrets"}} in helm_values["common"]["extraEnvFrom"]
    assert deployments["standalone"]["enabled"] is False
    assert deployments["worker"]["autoscaler"] == {
        "enabled": True,
        "minReplicas": 1,
        "maxReplicas": 5,
        "metrics": [
            {
                "type": "Resource",
                "resource": {
                    "name": "cpu",
                    "target": {"type": "Utilization", "averageUtilization": 70},
                },
            }
        ],
    }
    assert controller_only_values["deployments"]["worker"]["enabled"] is False
    assert controller_only_values["deployments"]["worker"]["autoscaler"]["enabled"] is False


def test_k8s_webserver_health_check_uses_management_port() -> None:
    helm_values = _yaml_load("k8s/helm/kestra-values.yaml")
    service = _yaml_document("k8s/base/service.yaml", kind="Service", name="kestra-webserver")
    backend_config = _yaml_load("k8s/overlays/dev/backendconfig.yaml")

    chart_ports = helm_values["service"]["ports"]
    service_ports = {port["name"]: port for port in service["spec"]["ports"]}

    assert chart_ports["http"]["containerPort"] == 8080
    assert chart_ports["management"]["containerPort"] == 8081
    assert chart_ports["grpc"]["containerPort"] == 50051
    assert service_ports["http"]["port"] == 80
    assert service_ports["http"]["targetPort"] == 8080
    assert service_ports["management"]["port"] == 8081
    assert service_ports["management"]["targetPort"] == 8081
    assert backend_config["spec"]["healthCheck"] == {
        "type": "HTTP",
        "port": 8081,
        "requestPath": "/health",
    }


def test_routed_image_build_installs_required_runtime_plugins() -> None:
    workflow = _yaml_load(".github/workflows/deploy.yml")
    build_routed_image = workflow["jobs"]["build-routed-image"]
    install_step = next(
        step for step in build_routed_image["steps"] if step["name"] == "Install runtime plugins"
    )

    assert "io.kestra.storage:storage-gcs:1.2.0" in install_step["run"]
    assert "io.kestra.plugin:plugin-script-shell:1.9.0" in install_step["run"]
    assert "io.kestra.plugin:plugin-kubernetes:1.9.5" in install_step["run"]


def test_k8s_podcreate_rbac_allows_batch_pod_lifecycle() -> None:
    kustomization = _yaml_load("k8s/base/kustomization.yaml")
    role = _yaml_document(
        "k8s/base/kestra-podcreate-rbac.yaml", kind="Role", name="kestra-podcreate"
    )
    binding = _yaml_document(
        "k8s/base/kestra-podcreate-rbac.yaml", kind="RoleBinding", name="kestra-podcreate"
    )

    assert "kestra-podcreate-rbac.yaml" in kustomization["resources"]
    assert role["rules"] == [
        {
            "apiGroups": [""],
            "resources": ["pods"],
            "verbs": ["create", "delete", "get", "list", "watch"],
        },
        {"apiGroups": [""], "resources": ["pods/log"], "verbs": ["get", "list", "watch"]},
    ]
    assert binding["subjects"] == [
        {"kind": "ServiceAccount", "name": "kestra", "namespace": "kestra"}
    ]
    assert binding["roleRef"]["name"] == "kestra-podcreate"


def test_gke_apply_cleans_legacy_kustomize_resources_before_helm_install() -> None:
    script = _read_text("scripts/apply-gke-dev.sh")
    cleanup_block_start = script.index('if ! helm status "$HELM_RELEASE"')
    helm_install_start = script.index('helm upgrade --install "$HELM_RELEASE"')
    cleanup_block = script[cleanup_block_start:helm_install_start]

    assert "delete configmap kestra-config --ignore-not-found" in cleanup_block
    assert "delete service kestra --ignore-not-found" in cleanup_block
    assert "kestra-webserver" in cleanup_block
    assert "kestra-executor" in cleanup_block
    assert "kestra-scheduler" in cleanup_block
    assert "kestra-indexer" in cleanup_block
    assert "delete hpa kestra-worker --ignore-not-found" in cleanup_block


def test_live_external_gce_worker_mode_disables_gke_worker() -> None:
    workflow = _yaml_load(".github/workflows/deploy.yml")
    deploy_env = workflow["jobs"]["deploy"]["env"]
    script = _read_text("scripts/apply-gke-dev.sh")
    verify_script = _read_text("scripts/verify-live-environments.sh")

    assert deploy_env["LIVE_GKE_EXTERNAL_GCE_WORKER_ENABLED"] == "true"
    assert deploy_env["GKE_WORKER_ENABLED"] == "false"
    assert deploy_env["LIVE_GKE_CONTROLLER_WORKER_ENABLED"] == "false"
    assert deploy_env["LIVE_GKE_ROUTED_WORKERS_ENABLED"] == "false"
    assert deploy_env["KESTRA_K8S_ADDITIONAL_FLOW_DIRS"] == "kestra/flows-federated"
    assert Path(deploy_env["KESTRA_K8S_ADDITIONAL_FLOW_DIRS"]).is_dir()
    assert 'LIVE_GKE_EXTERNAL_GCE_WORKER_ENABLED:-false}" == "true"' in script
    assert "GKE_WORKER_ENABLED=false" in script
    assert 'GKE_WORKER_ENABLED="${GKE_WORKER_ENABLED:-true}"' in script
    assert 'verify_environment k8s "https://${LIVE_GKE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}" false' in (
        verify_script
    )


def test_flow_registration_retries_transient_api_failures() -> None:
    script = _read_text("scripts/register-flows.sh")

    assert 'REGISTER_FLOW_ATTEMPTS="${REGISTER_FLOW_ATTEMPTS:-6}"' in script
    assert "retryable_status" in script
    assert '[[ "${status}" == "000"' in script
    assert '"${status}" =~ ^5' in script
    assert "Flow registration for ${flow} returned HTTP ${status}; retrying" in script
    assert "shopt -s nullglob" in script
    assert "No flow YAML files found in ${FLOW_DIR}" in script


def test_routed_live_deploy_enables_controller_and_routed_workers() -> None:
    script = _read_text("scripts/deploy-routed-live.sh")

    assert "export GKE_WORKER_ENABLED=false" in script
    assert "export LIVE_GKE_CONTROLLER_WORKER_ENABLED=true" in script
    assert "export LIVE_GKE_ROUTED_WORKERS_ENABLED=true" in script


def test_live_health_check_accepts_root_when_ui_route_is_absent() -> None:
    script = _read_text("scripts/verify-live-environments.sh")
    wait_start = script.index("wait_for_ui()")
    verify_start = script.index("verify_environment()", wait_start)
    wait_block = script[wait_start:verify_start]

    assert '"${url%/}/ui/"' in wait_block
    assert '"${url%/}/"' in wait_block
    assert "|| \\" in wait_block


def test_live_config_disables_routed_gke_workers_by_default(tmp_path: Path) -> None:
    result = _run_bash("scripts/render-live-config.sh", env=_live_config_env(tmp_path))
    gke_tfvars = (tmp_path / "gke-dev.tfvars").read_text(encoding="utf-8")

    assert result.returncode == 0
    assert "controller_worker_enabled      = true" in gke_tfvars
    assert "routed_workers                 = {}" in gke_tfvars
    assert "gce-a = {" not in gke_tfvars
    assert "gce-b = {" not in gke_tfvars


def test_live_config_enables_routed_gke_workers_for_routed_deploy(tmp_path: Path) -> None:
    result = _run_bash(
        "scripts/render-live-config.sh",
        env={
            **_live_config_env(tmp_path),
            "LIVE_GKE_ROUTED_WORKERS_ENABLED": "true",
            "LIVE_GKE_ROUTED_WORKER_MACHINE_TYPE": "e2-medium",
        },
    )
    gke_tfvars = (tmp_path / "gke-dev.tfvars").read_text(encoding="utf-8")

    assert result.returncode == 0
    assert 'worker_group_id = "gce-a"' in gke_tfvars
    assert 'worker_group_id = "gce-b"' in gke_tfvars
    assert 'machine_type    = "e2-medium"' in gke_tfvars
    assert "routed_workers                 = {}" not in gke_tfvars


def test_normal_gke_deploy_destroys_routed_workers_before_apply() -> None:
    script = _read_text("scripts/deploy-live-environments.sh")
    destroy_start = script.index("destroy_gke_routed_workers_if_disabled()")
    deploy_start = script.index("deploy_gke_dev()")
    destroy_block = script[destroy_start:deploy_start]
    deploy_block = script[deploy_start : script.index("case ", deploy_start)]

    assert '[[ "${LIVE_GKE_ROUTED_WORKERS_ENABLED:-false}" == "true" ]]' in destroy_block
    assert 'tofu -chdir="infra/terraform/gke-dev" apply' in destroy_block
    assert "-destroy \\" in destroy_block
    assert '-target="google_compute_instance.routed_worker"' in destroy_block
    assert deploy_block.index("destroy_gke_routed_workers_if_disabled") < deploy_block.index(
        'apply_tofu "infra/terraform/gke-dev"'
    )


def test_routed_worker_verification_uses_process_task_runner() -> None:
    flow = _yaml_load("kestra/flows-worker-routing/verify_gcp_worker_routing.yaml")

    for task in flow["tasks"]:
        assert task["workerSelector"]["fallback"] == "FAIL"
        assert task["taskRunner"] == {"type": "io.kestra.plugin.core.runner.Process"}
        assert task["timeout"] == "PT2M"


def test_gke_routed_worker_queues_are_declared() -> None:
    configmap = _yaml_document(
        "k8s/base/configmap.yaml", kind="ConfigMap", name="kestra-runtime-config"
    )
    app_config = yaml.safe_load(configmap["data"]["application.yaml"])
    routing = app_config["kestra"]["worker"]["routing"]

    assert routing["groups"]["gke-small"]["queues"] == [
        {"workerQueueId": "gke-small", "reservedPercent": -1}
    ]
    assert routing["groups"]["gke-large"]["queues"] == [
        {"workerQueueId": "gke-large", "reservedPercent": -1}
    ]
    assert routing["queues"]["gke-small"]["tags"] == ["gke-small"]
    assert routing["queues"]["gke-large"]["tags"] == ["gke-large"]


def test_gke_node_worker_routing_flow_uses_worker_selectors() -> None:
    flow = _yaml_load("kestra/flows-worker-routing/verify_gke_node_worker_routing.yaml")

    assert [task["id"] for task in flow["tasks"]] == [
        "run_on_gke_small",
        "run_on_gke_large",
    ]
    assert [task["workerSelector"]["tags"] for task in flow["tasks"]] == [
        ["gke-small"],
        ["gke-large"],
    ]
    for task in flow["tasks"]:
        assert task["workerSelector"]["fallback"] == "FAIL"
        assert task["taskRunner"] == {"type": "io.kestra.plugin.core.runner.Process"}
        assert task["timeout"] == "PT2M"


def test_gke_apply_script_supports_optional_placement_constrained_routed_workers() -> None:
    script = _read_text("scripts/apply-gke-dev.sh")

    assert "LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED" in script
    assert "kestra-gke-worker-small" in script
    assert "kestra-gke-worker-large" in script
    assert "workerGroupId: ${group_id}" in script
    assert "nodeName: ${node_name}" in script
    assert "${selector_key}: ${selector_value}" in script
    assert "tolerations:" in script
    assert "effect: NoSchedule" in script
    assert "LIVE_GKE_ROUTED_K8S_WORKER_SMALL_NODE_NAME" in script
    assert "LIVE_GKE_ROUTED_K8S_WORKER_LARGE_NODE_NAME" in script
    assert "LIVE_GKE_ROUTED_K8S_WORKER_SMALL_NODE_SELECTOR_KEY" in script
    assert "exec /app/kestra server worker --thread=${threads}" in script


def test_gke_terraform_supports_standard_autoscaled_worker_node_pools() -> None:
    main_tf = _read_text("infra/terraform/gke-dev/main.tf")
    variables_tf = _read_text("infra/terraform/gke-dev/variables.tf")

    assert 'variable "gke_autopilot_enabled"' in variables_tf
    assert "default     = true" in variables_tf
    assert 'variable "gke_standard_node_pools"' in variables_tf
    assert '"kestra.tacogips.io/worker-group" = "gke-small"' in variables_tf
    assert '"kestra.tacogips.io/worker-group" = "gke-large"' in variables_tf
    assert 'effect = "NO_SCHEDULE"' in variables_tf
    assert "enable_autopilot         = var.gke_autopilot_enabled" in main_tf
    assert 'resource "google_container_node_pool" "standard_worker"' in main_tf
    assert "for_each = var.gke_autopilot_enabled ? {} : var.gke_standard_node_pools" in main_tf
    assert "min_node_count = each.value.min_count" in main_tf
    assert "max_node_count = each.value.max_count" in main_tf
    assert '"kestra.tacogips.io/node-pool" = each.key' in main_tf
    assert 'dynamic "taint"' in main_tf


def test_gke_node_routing_verifier_registers_and_checks_flow() -> None:
    taskfile = _yaml_load("Taskfile.yml")
    script = _read_text("scripts/verify-live-gke-node-routing.sh")

    assert "kestra:live:run-gke-node-routing" in taskfile["tasks"]
    assert "verify_gke_node_worker_routing" in script
    assert "kestra/flows-worker-routing" in script
    assert "app.kubernetes.io/name=kestra-gke-routed-worker" in script
    assert "logs deployment/kestra-gke-worker-small -c kestra-worker --tail=80" in script


def test_k8s_pod_resource_flow_uses_distinct_pod_resources_without_node_pin() -> None:
    flow = _yaml_load("kestra/flows-k8s-pod-resources/verify_k8s_pod_resources.yaml")
    tasks = {task["id"]: task for task in flow["tasks"]}

    small = tasks["batch_1_small_pod"]["spec"]["containers"][0]["resources"]
    large = tasks["batch_2_large_pod"]["spec"]["containers"][0]["resources"]

    assert tasks["batch_1_small_pod"]["type"] == "io.kestra.plugin.kubernetes.core.PodCreate"
    assert tasks["batch_2_large_pod"]["type"] == "io.kestra.plugin.kubernetes.core.PodCreate"
    assert tasks["batch_1_small_pod"]["delete"] is False
    assert tasks["batch_2_large_pod"]["delete"] is False
    assert tasks["batch_1_small_pod"]["metadata"]["labels"] == {
        "app.kubernetes.io/name": "kestra-pod-resource-verify",
        "kestra-playground.tacogips.io/execution": "{{ execution.id }}",
        "kestra-playground.tacogips.io/resource-class": "small",
    }
    assert tasks["batch_2_large_pod"]["metadata"]["labels"] == {
        "app.kubernetes.io/name": "kestra-pod-resource-verify",
        "kestra-playground.tacogips.io/execution": "{{ execution.id }}",
        "kestra-playground.tacogips.io/resource-class": "large",
    }
    assert small == {
        "requests": {"cpu": "500m", "memory": "512Mi"},
        "limits": {"cpu": "1", "memory": "1Gi"},
    }
    assert large == {
        "requests": {"cpu": "2", "memory": "4Gi"},
        "limits": {"cpu": "4", "memory": "8Gi"},
    }
    for task in flow["tasks"]:
        assert "nodeSelector" not in task["spec"]


def test_k8s_pod_resource_verifier_registers_resource_flow() -> None:
    taskfile = _yaml_load("Taskfile.yml")
    script = _read_text("scripts/verify-live-k8s-pod-resources.sh")

    assert "kestra:live:run-k8s-pod-resources" in taskfile["tasks"]
    assert "kestra/flows-k8s-pod-resources" in script
    assert 'FLOW_NAMESPACE="playground.k8s_pod_resources"' in script
    assert '-F "kubernetes_namespace=${NAMESPACE}"' in script
    assert "require_command kubectl" in script
    assert "pod_resources_json" in script
    assert "assert_pod_resources" in script
    assert 'assert_pod_resources "${pods_json}" small 500m 512Mi 1 1Gi' in script
    assert 'assert_pod_resources "${pods_json}" large 2 4Gi 4 8Gi' in script
    assert "cleanup_resource_pods" in script


def test_business_date_helper_resolves_default_business_date() -> None:
    result = _run_bash("source scripts/lib/business-date.sh; resolve_business_date")

    assert result.returncode == 0
    assert datetime.date.fromisoformat(result.stdout.strip())


def test_business_date_helper_prefers_explicit_argument() -> None:
    result = _run_bash(
        "source scripts/lib/business-date.sh; resolve_business_date 2026-06-26",
        env={"BUSINESS_DATE": "2026-06-25"},
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "2026-06-26"


def test_business_date_helper_rejects_invalid_calendar_date() -> None:
    result = _run_bash("source scripts/lib/business-date.sh; resolve_business_date 2026-99-99")

    assert result.returncode != 0
    assert "Invalid business date: 2026-99-99" in result.stderr


def test_business_date_helper_reports_missing_python() -> None:
    result = _run_bash(
        "source scripts/lib/business-date.sh; PATH=/nonexistent resolve_business_date 2026-06-26"
    )

    assert result.returncode != 0
    assert "Missing required command: python or python3" in result.stderr


def test_run_flow_rejects_invalid_business_date_before_curl() -> None:
    result = subprocess.run(
        [
            "scripts/run-flow.sh",
            "generate_ecommerce_mock_data",
            "2026-99-99",
            "http://127.0.0.1:1",
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert "Invalid business date: 2026-99-99" in result.stderr
    assert "curl" not in result.stderr.lower()


def test_live_health_verification_does_not_validate_unused_business_date(tmp_path: Path) -> None:
    _stub_executable(tmp_path, "curl")
    _stub_executable(tmp_path, "gcloud")
    _stub_executable(tmp_path, "jq")

    result = subprocess.run(
        [
            "scripts/verify-live-environments.sh",
            "unknown-target",
            "2026-99-99",
            "health",
        ],
        check=False,
        capture_output=True,
        env={**os.environ, "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}"},
        text=True,
    )

    assert result.returncode != 0
    assert "Unknown target environment: unknown-target" in result.stderr
    assert "Invalid business date" not in result.stderr


def test_live_batch_verification_rejects_invalid_business_date_before_commands() -> None:
    result = subprocess.run(
        [
            "scripts/verify-live-environments.sh",
            "unknown-target",
            "2026-99-99",
            "run-batch",
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert "Invalid business date: 2026-99-99" in result.stderr
    assert "Unknown target environment" not in result.stderr


def test_scripts_check_syntax_validates_each_shell_script() -> None:
    taskfile = _yaml_load("Taskfile.yml")
    scripts_check_commands = taskfile["tasks"]["scripts:check"]["cmds"]

    assert "xargs -0 -n 1 bash -n" in scripts_check_commands[0]


def _read_text(path: str) -> str:
    return Path(path).read_text(encoding="utf-8").rstrip()


def _flow_task_sql(path: str, task_id: str) -> str:
    task = _flow_task(path, task_id)
    try:
        return task["sql"].rstrip()
    except KeyError as exc:
        raise AssertionError(f"Task {task_id!r} does not contain a SQL block") from exc


def _flow_tasks_sql(path: str, task_ids: list[str]) -> str:
    return "\n\n".join(_flow_task_sql(path, task_id) for task_id in task_ids)


def _flow_task_ids(path: str) -> list[str]:
    return [task["id"] for task in _yaml_load(path)["tasks"]]


def _flow_task(path: str, task_id: str) -> dict[str, Any]:
    for task in _yaml_load(path)["tasks"]:
        if task["id"] == task_id:
            return task

    raise AssertionError(f"Task {task_id!r} was not found in {path}")


def _yaml_load(path: str) -> dict[str, Any]:
    return yaml.safe_load(_read_text(path))


def _yaml_document(path: str, *, kind: str, name: str) -> dict[str, Any]:
    for document in yaml.safe_load_all(_read_text(path)):
        if document["kind"] == kind and document["metadata"]["name"] == name:
            return document

    raise AssertionError(f"{kind} {name!r} was not found in {path}")


def _container_by_name(deployment: dict[str, Any], name: str) -> dict[str, Any]:
    for container in deployment["spec"]["template"]["spec"]["containers"]:
        if container["name"] == name:
            return container

    deployment_name = deployment["metadata"]["name"]
    raise AssertionError(f"Container {name!r} was not found in Deployment {deployment_name!r}")


def _run_bash(
    command: str, *, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", command],
        check=False,
        capture_output=True,
        env={**os.environ, **(env or {})},
        text=True,
    )


def _live_config_env(directory: Path) -> dict[str, str]:
    return {
        "LIVE_CONFIG_DIR": str(directory),
        "PROJECT_ID": "test-project",
        "LIVE_DOMAIN_NAME": "example.com",
        "CLOUDFLARE_ZONE_ID": "zone-id",
        "TOFU_STATE_BUCKET": "state-bucket",
    }


def _stub_executable(directory: Path, name: str) -> None:
    path = directory / name
    path.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)
