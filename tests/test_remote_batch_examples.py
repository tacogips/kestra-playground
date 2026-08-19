from __future__ import annotations

import csv
import json
import os
import sqlite3
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).parent.parent


def _run_batch(
    script: Path,
    config: Mapping[str, object],
    output_path: Path,
    phase: str | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["KESTRA_BATCH_CONFIG"] = json.dumps(config)
    env["KESTRA_BATCH_OUTPUT"] = str(output_path)
    command = [sys.executable, str(script)]
    if phase is not None:
        command.append(phase)
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def _load_yaml(path: str) -> dict[str, Any]:
    return yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))


def test_database_export_writes_csv_and_emits_progress(tmp_path: Path) -> None:
    database_path = tmp_path / "orders.db"
    with sqlite3.connect(database_path) as connection:
        connection.execute("CREATE TABLE orders (id INTEGER, status TEXT)")
        connection.executemany(
            "INSERT INTO orders VALUES (?, ?)",
            [(1, "completed"), (2, "cancelled")],
        )

    output_path = tmp_path / "orders.csv"
    result = _run_batch(
        ROOT / "batch-groups/ec/batches/db_export/export_database.py",
        {"database_path": str(database_path), "query": "SELECT * FROM orders ORDER BY id"},
        output_path,
    )

    assert result.returncode == 0, result.stderr
    assert "progress phase=connect" in result.stdout
    assert "progress phase=complete rows=2" in result.stdout
    assert '"exported_rows"' in result.stdout
    with output_path.open(encoding="utf-8", newline="") as output_file:
        assert list(csv.reader(output_file)) == [
            ["id", "status"],
            ["1", "completed"],
            ["2", "cancelled"],
        ]


def test_database_export_rejects_missing_database(tmp_path: Path) -> None:
    result = _run_batch(
        ROOT / "batch-groups/ec/batches/db_export/export_database.py",
        {"database_path": str(tmp_path / "missing.db"), "query": "SELECT 1"},
        tmp_path / "out.csv",
    )

    assert result.returncode == 64
    assert "batch_error type=FileNotFoundError" in result.stderr


def test_log_parser_writes_summary_and_counts_malformed_lines(tmp_path: Path) -> None:
    input_path = tmp_path / "application.jsonl"
    input_path.write_text(
        "\n".join(
            [
                json.dumps(
                    {
                        "timestamp": "2026-06-25T01:00:00Z",
                        "level": "INFO",
                        "service": "api",
                    }
                ),
                json.dumps(
                    {
                        "timestamp": "2026-06-25T01:01:00Z",
                        "level": "ERROR",
                        "service": "worker",
                    }
                ),
                json.dumps(
                    {
                        "timestamp": "2026-06-26T01:00:00Z",
                        "level": "INFO",
                        "service": "api",
                    }
                ),
                "not-json",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    output_path = tmp_path / "summary.json"

    result = _run_batch(
        ROOT / "batch-groups/ec/batches/log_parse/parse_logs.py",
        {"input_path": str(input_path), "business_date": "2026-06-25"},
        output_path,
    )

    assert result.returncode == 0, result.stderr
    assert "progress phase=parse malformed_line=4" in result.stdout
    summary = json.loads(output_path.read_text(encoding="utf-8"))
    assert summary == {
        "business_date": "2026-06-25",
        "input_file": "application.jsonl",
        "levels": {"ERROR": 1, "INFO": 1},
        "malformed_lines": 1,
        "matched_lines": 2,
        "services": {"api": 1, "worker": 1},
        "total_lines": 4,
    }


def test_log_parser_supports_independent_retryable_phases(tmp_path: Path) -> None:
    input_path = tmp_path / "application.jsonl"
    input_path.write_text(
        '{"timestamp":"2026-06-25T01:00:00Z","level":"INFO","service":"api"}\n',
        encoding="utf-8",
    )
    output_path = tmp_path / "summary.json"
    config = {"input_path": str(input_path), "business_date": "2026-06-25"}

    validate_input_result = _run_batch(
        ROOT / "batch-groups/ec/batches/log_parse/parse_logs.py",
        config,
        output_path,
        "validate-input",
    )
    assert validate_input_result.returncode == 0, validate_input_result.stderr
    assert "progress phase=input_validated" in validate_input_result.stdout
    assert not output_path.exists()

    execute_result = _run_batch(
        ROOT / "batch-groups/ec/batches/log_parse/parse_logs.py",
        config,
        output_path,
        "execute",
    )
    assert execute_result.returncode == 0, execute_result.stderr
    assert output_path.is_file()

    validate_output_result = _run_batch(
        ROOT / "batch-groups/ec/batches/log_parse/parse_logs.py",
        config,
        output_path,
        "validate-output",
    )
    assert validate_output_result.returncode == 0, validate_output_result.stderr
    assert "progress phase=output_validated" in validate_output_result.stdout


def test_remote_examples_delegate_all_execution_mechanics_to_framework() -> None:
    runner = _load_yaml("kestra/flows-remote-batch/00_remote_batch_runner.yaml")
    export_flow = _load_yaml("kestra/flows-remote-batch/export_database_to_csv.yaml")
    parse_flow = _load_yaml("kestra/flows-remote-batch/parse_application_logs.yaml")

    runner_types = [task["type"] for task in runner["tasks"]]
    assert runner_types == [
        "io.kestra.plugin.core.namespace.DownloadFiles",
        "io.kestra.plugin.fs.ssh.Command",
        "io.kestra.plugin.fs.sftp.Upload",
        "io.kestra.plugin.fs.ssh.Command",
        "io.kestra.plugin.fs.ssh.Command",
        "io.kestra.plugin.fs.ssh.Command",
        "io.kestra.plugin.fs.sftp.Download",
        "io.kestra.plugin.fs.ssh.Command",
    ]
    assert [task["id"] for task in runner["tasks"]] == [
        "resolve_source",
        "prepare_workspace",
        "stage_source",
        "validate_input",
        "execute_batch",
        "validate_output",
        "collect_artifact",
        "cleanup_workspace",
    ]
    assert runner["errors"][0]["id"] == "cleanup_failed_workspace"
    assert "workspace_cleaned verified=true" in runner["tasks"][-1]["commands"][0]
    assert "workspace_cleaned verified=true" in runner["errors"][0]["commands"][0]
    assert '[ -e "${workspace}" ] || [ -L "${workspace}" ]' in (runner["errors"][0]["commands"][0])
    for task in runner["tasks"]:
        assert task["retry"] == {
            "type": "constant",
            "maxAttempts": 2,
            "interval": "PT5S",
            "maxDuration": "PT5M",
        }
    execute = next(task for task in runner["tasks"] if task["id"] == "execute_batch")
    assert "retry_probe phase=execute_batch result=failed_once" in execute["commands"][0]
    assert "python3 main.py validate-input" in runner["tasks"][3]["commands"][0]
    assert "python3 main.py execute" in execute["commands"][0]
    assert "python3 main.py validate-output" in runner["tasks"][5]["commands"][0]

    for flow, script_name in (
        (export_flow, "batches/db_export/export_database.py"),
        (parse_flow, "batches/log_parse/parse_logs.py"),
    ):
        assert len(flow["tasks"]) == 1
        task = flow["tasks"][0]
        assert task["type"] == "io.kestra.plugin.core.flow.Subflow"
        assert task["flowId"] == "remote_batch_runner"
        assert task["wait"] is True
        assert task["transmitFailed"] is True
        assert task["inputs"]["script_name"] == script_name
        serialized = json.dumps(flow)
        assert "io.kestra.plugin.fs.ssh.Command" not in serialized
        assert "io.kestra.plugin.fs.sftp.Upload" not in serialized


def test_multi_target_runner_fans_out_and_retries_each_target_independently() -> None:
    runner = _load_yaml("kestra/flows-remote-batch/02_multi_target_remote_batch_runner.yaml")
    caller = _load_yaml("kestra/flows-remote-batch/parse_application_logs_multi_target.yaml")

    assert runner["inputs"][0] == {
        "id": "targets",
        "type": "JSON",
        "required": True,
        "description": (
            "Bounded array of unique target objects with id, host, port, username, "
            "password_secret, and execute_failure_marker. Values name Kestra secrets but never "
            "contain secret payloads."
        ),
    }
    fan_out = runner["tasks"][0]
    assert fan_out["type"] == "io.kestra.plugin.core.flow.Loop"
    assert fan_out["values"] == "{{ inputs.targets }}"
    assert fan_out["concurrencyLimit"] == 4

    target = fan_out["tasks"][0]
    assert target["type"] == "io.kestra.plugin.core.flow.Subflow"
    assert target["flowId"] == "remote_batch_runner"
    assert target["wait"] is True
    assert target["transmitFailed"] is True
    assert target["inputs"]["target_id"] == "{{ fromJson(item.value).id }}"
    assert target["inputs"]["worker_host"] == "{{ fromJson(item.value).host }}"
    assert target["inputs"]["worker_password_secret"] == (
        "{{ fromJson(item.value).password_secret }}"
    )
    assert target["inputs"]["execute_failure_marker"] == (
        "{{ fromJson(item.value).execute_failure_marker }}"
    )
    assert target["retry"] == {
        "type": "constant",
        "maxAttempts": 3,
        "interval": "PT30S",
        "maxDuration": "PT30M",
    }

    assert len(caller["tasks"]) == 1
    assert caller["tasks"][0]["flowId"] == "multi_target_remote_batch_runner"
    assert caller["tasks"][0]["inputs"]["targets"] == "{{ inputs.targets }}"


def test_local_compose_provisions_two_external_ssh_workers() -> None:
    compose = _load_yaml("local/docker/docker-compose.yml")
    services = compose["services"]

    for service_name in ("remote-worker", "remote-worker-b"):
        worker = services[service_name]
        assert worker["build"]["context"] == "./remote-worker"
        assert worker["env_file"] == ["../../batch-groups/ec/config/envs/local.env"]
        assert "ssh-keyscan" in worker["healthcheck"]["test"][1]


def test_multi_target_verifier_proves_retry_is_isolated() -> None:
    script = (ROOT / "scripts/verify-local-remote-batch-multi-target.sh").read_text(
        encoding="utf-8"
    )

    assert "inject_second_worker_execute_failure" in script
    assert "assert_child_step_attempts" in script
    assert "correlated_execution_id" in script
    assert ".metadata.attemptNumber == 1" in script
    assert 'assert_child_step_attempts "${retry_worker_a_id}" worker-a 1' in script
    assert 'assert_child_step_attempts "${retry_worker_b_id}" worker-b 2' in script
    assert '.taskId == "validate_input"' in script
    assert '.taskId == "validate_output"' in script
    assert "for worker in remote-worker remote-worker-b" in script
    assert "assert_no_target_kestra_runtime" in script


def test_gcp_target_scripts_keep_secrets_out_of_metadata_and_test_retry() -> None:
    provision = (ROOT / "scripts/provision-live-remote-batch-targets.sh").read_text(
        encoding="utf-8"
    )
    startup = (ROOT / "scripts/live-remote-batch-target-startup.sh").read_text(encoding="utf-8")
    verify = (ROOT / "scripts/verify-live-remote-batch-ssh.sh").read_text(encoding="utf-8")

    assert "--metadata-from-file=startup-script=" in provision
    assert "https://api.ipify.org" in provision
    assert "valid IPv4 source address" in provision
    assert "REMOTE_BATCH_PASSWORD is required" in provision
    assert "--metadata=remote-batch-password" not in provision
    assert "sudo chpasswd" in provision
    assert "kestra-remote-batch-sshd-control.service" in startup
    assert "remote-batch-sshd-disabled" in startup
    assert "inject_target_b_execute_failure" in verify
    assert "correlated_execution_id" in verify
    assert 'assert_child_step_attempts "${retry_worker_a_id}" gcp-worker-a 1' in verify
    assert 'assert_child_step_attempts "${retry_worker_b_id}" gcp-worker-b 2' in verify
    assert '.taskId == "validate_input"' in verify
    assert '.taskId == "validate_output"' in verify
    assert "assert_no_target_kestra_runtime" in verify
    assert "Unexpected Kestra process on remote target" in verify


def test_routed_examples_need_only_uv_on_the_selected_worker() -> None:
    runner = _load_yaml("kestra/flows-remote-batch/01_routed_batch_runner.yaml")
    export_flow = _load_yaml("kestra/flows-remote-batch/export_database_to_csv_routed.yaml")
    parse_flow = _load_yaml("kestra/flows-remote-batch/parse_application_logs_routed.yaml")

    assert len(runner["tasks"]) == 1
    selector = runner["tasks"][0]
    assert selector["type"] == "io.kestra.plugin.core.flow.Switch"
    assert set(selector["cases"]) == {"gke-small", "gke-large"}
    for worker_group in ("gke-small", "gke-large"):
        execute = selector["cases"][worker_group][0]
        assert execute["type"] == "io.kestra.plugin.scripts.shell.Commands"
        assert execute["taskRunner"]["type"] == "io.kestra.plugin.core.runner.Process"
        assert execute["workerSelector"] == {
            "tags": [worker_group],
            "match": "ALL",
            "fallback": "FAIL",
        }
        assert execute["inputFiles"] == {"batch.tar.gz": "{{ inputs.batch_bundle }}"}
        assert execute["outputFiles"] == ["{{ inputs.output_file }}"]
        assert execute["env"]["KESTRA_BATCH_OUTPUT"] == "{{ inputs.output_file }}"
        assert execute["env"]["UV_CACHE_DIR"] == ".uv-cache"
        assert execute["env"]["UV_PYTHON_INSTALL_DIR"] == ".uv-python"
        assert "uv run --no-project" in execute["commands"][0]
        assert "trap cleanup_runtime EXIT" in execute["commands"][0]
        assert "progress phase=runtime_cleaned verified=true" in execute["commands"][0]
        assert 'if [ -e "${runtime_path}" ] || [ -L "${runtime_path}" ]' in (execute["commands"][0])

    for flow, expected_group in (
        (export_flow, "gke-small"),
        (parse_flow, "gke-large"),
    ):
        assert len(flow["tasks"]) == 1
        assert flow["tasks"][0]["flowId"] == "routed_batch_runner"
        worker_group_input = next(item for item in flow["inputs"] if item["id"] == "worker_group")
        assert worker_group_input["defaults"] == expected_group
        serialized = json.dumps(flow)
        assert "io.kestra.plugin.fs.ssh.Command" not in serialized
        assert "io.kestra.plugin.fs.sftp.Upload" not in serialized


def test_local_compose_provisions_an_external_ssh_worker_and_kestra_secret() -> None:
    compose = _load_yaml("local/docker/docker-compose.yml")
    services = compose["services"]
    ec_env = (ROOT / "batch-groups/ec/config/envs/local.env.example").read_text(encoding="utf-8")

    assert services["remote-worker"]["build"]["context"] == "./remote-worker"
    expected_env_file = ["../../batch-groups/ec/config/envs/local.env"]
    assert services["remote-worker"]["env_file"] == expected_env_file
    assert services["kestra-ec"]["env_file"] == expected_env_file
    assert "REMOTE_BATCH_PASSWORD=local" in ec_env
    assert "SECRET_REMOTE_BATCH_PASSWORD=bG9jYWw=" in ec_env
