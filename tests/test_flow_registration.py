"""Exercise flow replacement against both API generations."""

import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from threading import Thread

import pytest


@pytest.mark.parametrize(
    ("status", "response", "expected_methods"),
    [
        (422, {"message": "Flow id already exists"}, ["POST", "PUT"]),
        (
            409,
            {"type": "https://kestra.io/docs/api-reference/problems/entity-already-exists"},
            ["POST", "PUT"],
        ),
        (409, {"detail": "Concurrent update"}, ["POST"]),
    ],
)
def test_register_replaces_only_duplicate_flows(
    tmp_path: Path, status: int, response: dict[str, str], expected_methods: list[str]
) -> None:
    methods: list[str] = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            self.send_response(200)
            self.end_headers()

        def do_POST(self) -> None:
            methods.append("POST")
            self.rfile.read(int(self.headers["Content-Length"]))
            self.send_response(status)
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())

        def do_PUT(self) -> None:
            methods.append("PUT")
            assert self.path == "/api/v1/main/flows/test.namespace/example"
            self.rfile.read(int(self.headers["Content-Length"]))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"{}")

        def log_message(self, format: str, *args: object) -> None:
            pass

    (tmp_path / "example.yaml").write_text(
        "id: example\nnamespace: test.namespace\ntasks: []\n", encoding="utf-8"
    )
    with HTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = Thread(target=server.serve_forever)
        thread.start()
        try:
            result = subprocess.run(
                [
                    "bash",
                    "scripts/register-flows.sh",
                    f"http://127.0.0.1:{server.server_port}",
                    str(tmp_path),
                ],
                env={"PATH": os.environ["PATH"], "REGISTER_FLOW_ATTEMPTS": "1"},
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        finally:
            server.shutdown()
            thread.join()
    assert methods == expected_methods
    assert (result.returncode == 0) == (expected_methods == ["POST", "PUT"]), result.stderr
