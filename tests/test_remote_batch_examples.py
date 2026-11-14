from __future__ import annotations

import csv
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).parent.parent


def _run_batch(
    script: Path, config: dict[str, object], output_path: Path
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["KESTRA_BATCH_CONFIG"] = json.dumps(config)
    env["KESTRA_BATCH_OUTPUT"] = str(output_path)
    return subprocess.run(
        [sys.executable, str(script)],
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
        ROOT / "batches/db_export/export_database.py",
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
        ROOT / "batches/db_export/export_database.py",
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
        ROOT / "batches/log_parse/parse_logs.py",
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
        "io.kestra.plugin.fs.sftp.Download",
        "io.kestra.plugin.fs.ssh.Command",
    ]
    assert [task["id"] for task in runner["tasks"]] == [
        "resolve_source",
        "prepare_workspace",
        "stage_source",
        "execute_batch",
        "collect_artifact",
        "cleanup_workspace",
    ]
    assert runner["errors"][0]["id"] == "cleanup_failed_workspace"
    assert "workspace_cleaned verified=true" in runner["tasks"][-1]["commands"][0]
    assert "workspace_cleaned verified=true" in runner["errors"][0]["commands"][0]
    assert '[ -e "${workspace}" ] || [ -L "${workspace}" ]' in (runner["errors"][0]["commands"][0])

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

    assert services["remote-worker"]["build"]["context"] == "./remote-worker"
    assert services["remote-worker"]["environment"]["REMOTE_BATCH_PASSWORD"] == (
        "${REMOTE_BATCH_PASSWORD:-remote-batch-local}"
    )
    assert services["kestra"]["environment"]["SECRET_REMOTE_BATCH_PASSWORD"] == (
        "${SECRET_REMOTE_BATCH_PASSWORD:-cmVtb3RlLWJhdGNoLWxvY2Fs}"
    )
