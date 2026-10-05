"""Verify the packaged plugin in the isolated local Compose runtime."""

import base64
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
COMPOSE = ROOT / "local/compose.yaml"
BASE_URL = os.environ.get(
    "PYTHON_TASK_URL", f"http://127.0.0.1:{os.environ.get('PYTHON_TASK_PORT', '18080')}"
).rstrip("/")
CREDENTIALS = base64.b64encode(b"local@example.com:LocalPythonTask123!").decode()
# JSON data is an external API boundary; all structures are asserted below.
type JsonObject = dict[str, Any]


def request(
    path: str,
    method: str = "GET",
    data: bytes | None = None,
    content_type: str | None = None,
) -> bytes:
    """Send an authenticated request to the local test server."""
    headers = {"Authorization": f"Basic {CREDENTIALS}"}
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(BASE_URL + path, data, headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        raise RuntimeError(
            f"{method} {path}: HTTP {error.code}: {error.read().decode()}"
        ) from error


def compose_exec(code: str) -> str:
    """Run a Python inspection directly in the test container without a shell."""
    return subprocess.check_output(
        ["docker", "compose", "-f", str(COMPOSE), "exec", "-T", "kestra", "python3", "-c", code],
        text=True,
    ).strip()


def register(flow: str) -> None:
    """Register and validate a test flow."""
    try:
        request("/api/v1/main/flows", "POST", flow.encode(), "application/x-yaml")
    except RuntimeError as error:
        if "Flow id already exists" not in str(error):
            raise
        flow_id = flow.splitlines()[0].removeprefix("id: ").strip()
        request(
            f"/api/v1/main/flows/playground.pythontask/{flow_id}",
            "PUT",
            flow.encode(),
            "application/x-yaml",
        )


def execute(flow_id: str, payload: str | None = None) -> JsonObject:
    """Start an execution and wait for a terminal state."""
    boundary = "python-task-verification-boundary"
    content_type = f"multipart/form-data; boundary={boundary}"
    if payload is None:
        body = f"--{boundary}--\r\n".encode()
    else:
        body = (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="payload"\r\n\r\n'
            f"{payload}\r\n--{boundary}--\r\n"
        ).encode()
    execution: JsonObject = json.loads(
        request(
            f"/api/v1/main/executions/playground.pythontask/{flow_id}",
            "POST",
            body,
            content_type,
        )
    )
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        execution = json.loads(request(f"/api/v1/main/executions/{execution['id']}"))
        if execution["state"]["current"] in {
            "SUCCESS",
            "FAILED",
            "KILLED",
            "CANCELLED",
            "WARNING",
        }:
            return execution
        time.sleep(1)
    raise TimeoutError(f"Execution {execution['id']} did not finish")


def single_task(flow_id: str, properties: str) -> str:
    """Generate a one-task negative test flow."""
    return (
        f"id: {flow_id}\nnamespace: playground.pythontask\ntasks:\n"
        "  - id: run\n    type: io.kestra.plugin.pythontask.PythonTask\n" + properties
    )


def main() -> None:
    """Assert argv fidelity, storage output, failure propagation, and cleanup."""
    deadline = time.monotonic() + 240
    while True:
        try:
            request("/api/v1/main/flows/search")
            break
        except (OSError, RuntimeError):
            if time.monotonic() > deadline:
                raise TimeoutError("Local Kestra API did not become ready") from None
            time.sleep(2)

    compose_exec(
        "from pathlib import Path; "
        "[p.unlink(missing_ok=True) for p in "
        "[Path('/tmp/python-task-injected'), Path('/tmp/python-task-child.pid'), "
        "Path('/tmp/python-task-parent.pid')]]"
    )
    register((ROOT / "examples/flow.yaml").read_text())
    payloads = [
        "ordinary input with spaces",
        "--another-option=a=b",
        "'; touch /tmp/python-task-injected; #",
        '"; touch /tmp/python-task-injected; #',
        "$(touch /tmp/python-task-injected)",
        "`touch /tmp/python-task-injected`",
        "line one\nline two; touch /tmp/python-task-injected\n日本語 {{ 7 * 7 }}",
    ]
    records: list[JsonObject] = []
    for payload in payloads:
        execution = execute("python_task_arguments", payload)
        assert execution["state"]["current"] == "SUCCESS", execution
        for task, expected in [
            ("default_python", ["echo", payload, "", "two words", "--flag=value", "日本語"]),
            ("explicit_python", [payload, "explicit"]),
            (
                "mapped_options",
                [
                    "echo",
                    f"--customer={payload}",
                    "--empty=",
                    "--output=report.csv",
                    "--verbose",
                    "--dry-run",
                ],
            ),
        ]:
            output = next(
                run["outputs"] for run in execution["taskRunList"] if run["taskId"] == task
            )
            observed = json.loads(output["stdout"])
            assert observed == {"args": expected, "cwd": "/opt/python-task-examples"}, observed
            assert output["exitCode"] == 0, output
            assert output["stderr"] == "", output
            # Check complete streams were uploaded and can be read through Kestra.
            stored = request(
                f"/api/v1/main/executions/{execution['id']}/file?path="
                + urllib.parse.quote(output["stdoutUri"], safe="")
            )
            assert json.loads(stored) == observed, stored
        parsed = next(
            run["outputs"] for run in execution["taskRunList"] if run["taskId"] == "parsed_options"
        )
        assert json.loads(parsed["stdout"]) == {
            "customer": payload,
            "output": "report.csv",
            "verbose": True,
            "dry_run": True,
        }, parsed
        records.append({"id": execution["id"], "case": payload, "state": "SUCCESS"})
        print(f"PASS argv round-trip: {execution['id']}", flush=True)
    assert (
        compose_exec("from pathlib import Path; print(Path('/tmp/python-task-injected').exists())")
        == "False"
    )

    register(
        single_task(
            "python_task_defaults", "    cwd: /opt/python-task-examples\n    cmd: inspect_args.py\n"
        )
    )
    defaults = execute("python_task_defaults")
    assert defaults["state"]["current"] == "SUCCESS", defaults
    assert json.loads(defaults["taskRunList"][0]["outputs"]["stdout"])["args"] == []
    records.append({"id": defaults["id"], "case": "omitted args", "state": "SUCCESS"})

    register(
        single_task(
            "python_task_null_option",
            "    cwd: /opt/python-task-examples\n"
            "    cmd: inspect_args.py\n    options: {customer: null}\n",
        )
    )
    omitted = execute("python_task_null_option")
    assert omitted["state"]["current"] == "SUCCESS", omitted
    assert json.loads(omitted["taskRunList"][0]["outputs"]["stdout"])["args"] == []
    records.append({"id": omitted["id"], "case": "null option omitted", "state": "SUCCESS"})

    negative_cases = [
        (
            "python_task_invalid_option",
            "    cwd: /opt/python-task-examples\n"
            '    cmd: inspect_args.py\n    options: {"--customer": "value"}\n',
        ),
        (
            "python_task_invalid_flag",
            "    cwd: /opt/python-task-examples\n"
            '    cmd: inspect_args.py\n    flags: ["verbose; touch /tmp/python-task-injected"]\n',
        ),
        (
            "python_task_failure",
            "    cwd: /opt/python-task-examples\n    cmd: inspect_args.py\n    args: [fail]\n",
        ),
        (
            "python_task_timeout",
            "    cwd: /opt/python-task-examples\n"
            "    cmd: inspect_args.py\n    args: [wait]\n    processTimeout: PT2S\n",
        ),
        (
            "python_task_invalid_cwd",
            "    cwd: /missing-python-task-directory\n    cmd: inspect_args.py\n",
        ),
        ("python_task_missing_script", "    cwd: /opt/python-task-examples\n    cmd: missing.py\n"),
        (
            "python_task_render_failure",
            "    cwd: /opt/python-task-examples\n"
            '    cmd: inspect_args.py\n    args: ["{{ inputs.missing }}"]\n',
        ),
    ]
    for flow_id, properties in negative_cases:
        register(single_task(flow_id, properties))
        execution = execute(flow_id)
        assert execution["state"]["current"] == "FAILED", execution
        logs = json.loads(request(f"/api/v1/main/logs/{execution['id']}"))
        assert logs, f"No error diagnostics for {flow_id}"
        if flow_id == "python_task_failure":
            assert "exited with code 7" in json.dumps(logs), logs
        if flow_id == "python_task_timeout":
            assert "exceeded processTimeout" in json.dumps(logs), logs
        records.append({"id": execution["id"], "case": flow_id, "state": "FAILED"})
        print(f"PASS expected failure: {flow_id} {execution['id']}", flush=True)

    status = compose_exec(
        "from pathlib import Path; import os; "
        "pids = [int(Path('/tmp/python-task-' + role + '.pid').read_text()) "
        "for role in ['parent', 'child']]; "
        "print([pid for pid in pids if Path('/proc/' + str(pid)).exists() "
        "and Path('/proc/' + str(pid) + '/stat').read_text().split()[2] != 'Z'])"
    )
    assert status == "[]", f"Timeout left running processes: {status}"
    results = ROOT / "local/results"
    results.mkdir(exist_ok=True)
    (results / "executions.json").write_text(json.dumps(records, indent=2, ensure_ascii=False))
    print("PASS: no injected marker; timeout parent and child stopped; all cases verified")


if __name__ == "__main__":
    main()
