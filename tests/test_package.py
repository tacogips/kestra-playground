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
    configmap = _yaml_document("k8s/base/configmap.yaml", kind="ConfigMap", name="kestra-config")
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


def test_k8s_kestra_components_have_distinct_otel_service_names() -> None:
    kustomization = _yaml_load("k8s/base/kustomization.yaml")
    expected = {
        "k8s/base/webserver.yaml": ("kestra-webserver", "kestra-webserver"),
        "k8s/base/executor.yaml": ("kestra-executor", "kestra-executor"),
        "k8s/base/scheduler.yaml": ("kestra-scheduler", "kestra-scheduler"),
        "k8s/base/indexer.yaml": ("kestra-indexer", "kestra-indexer"),
    }

    assert "worker.yaml" not in kustomization["resources"]
    assert not Path("k8s/base/worker.yaml").exists()

    for path, (deployment_name, service_name) in expected.items():
        deployment = _yaml_document(path, kind="Deployment", name=deployment_name)
        kestra_container = _container_by_name(deployment, "kestra")
        env = {item["name"]: item["value"] for item in kestra_container["env"] if "value" in item}

        assert env["OTEL_SERVICE_NAME"] == service_name
        assert env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://otel-collector:4317"
        assert (
            f"kestra.component={service_name.removeprefix('kestra-')}"
            in env["OTEL_RESOURCE_ATTRIBUTES"]
        )


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


def _stub_executable(directory: Path, name: str) -> None:
    path = directory / name
    path.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)
