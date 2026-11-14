"""Guard the migrated flows and output retrieval across Kestra API versions."""

import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from threading import Thread

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_ec_flows_inline_removed_plugin_defaults() -> None:
    paths = list((ROOT / "batch-groups/ec/flows").glob("*.yaml"))
    paths += list((ROOT / "kestra/flows-notification").glob("*.yaml"))
    expected = {
        "io.kestra.plugin.jdbc.postgresql.Queries": {"url", "username", "password"},
        "io.kestra.plugin.email.MailSend": {"host", "port", "from", "to", "transportStrategy"},
    }
    for path in paths:
        flow = yaml.safe_load(path.read_text(encoding="utf-8"))
        assert "pluginDefaults" not in flow, path
        for section in ("tasks", "afterExecution", "errors", "finally"):
            for task in flow.get(section, []):
                required = expected.get(task["type"], set())
                assert required <= task.keys(), (path, task["id"])


@pytest.mark.parametrize("legacy", [True, False])
def test_fetch_execution_preserves_outputs_across_api_versions(legacy: bool) -> None:
    execution: dict[str, object] = {
        "id": "execution",
        "state": {"current": "SUCCESS"},
        "taskRunList": [{"id": "task-run", "taskId": "subflow"}],
    }
    if legacy:
        execution["outputs"] = {"artifact": "kestra:///result"}
    responses = {
        "/api/v1/main/executions/execution": execution,
        "/api/v1/main/outputs/executions/execution": {"artifact": "kestra:///result"},
        "/api/v1/main/outputs/tasks/execution": [{"taskRunId": "task-run"}],
        "/api/v1/main/outputs/tasks/execution/task-run": {"executionId": "child-execution"},
    }
    requests: list[str] = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            requests.append(self.path)
            self.send_response(200 if self.path in responses else 404)
            self.end_headers()
            self.wfile.write(json.dumps(responses.get(self.path, {})).encode())

        def log_message(self, format: str, *args: object) -> None:
            pass

    with HTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = Thread(target=server.serve_forever)
        thread.start()
        try:
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/fetch-execution-with-outputs.sh"), "execution"],
                env={
                    "PATH": os.environ["PATH"],
                    "KESTRA_URL": f"http://127.0.0.1:{server.server_port}",
                },
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        finally:
            server.shutdown()
            thread.join()
    assert result.returncode == 0, result.stderr
    fetched = json.loads(result.stdout)
    assert fetched["outputs"] == {"artifact": "kestra:///result"}
    if legacy:
        assert requests == ["/api/v1/main/executions/execution"]
    else:
        assert fetched["taskRunList"][0]["outputs"] == {"executionId": "child-execution"}
