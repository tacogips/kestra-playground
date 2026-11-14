import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from kestra_playground.kestra_reconcile import (
    CategoryManifest,
    FlowDefinition,
    KestraApiClient,
    ReconcileError,
    _parse_flow,
    build_plan,
    load_desired_flows,
    reconcile,
)


def _manifest(flow_directory: Path, *, max_deletes: int = 10) -> CategoryManifest:
    return CategoryManifest(
        id="orders",
        release_tag_prefix="orders-controller-v",
        flow_directory=flow_directory,
        namespace="playground.orders.staging",
        deployment_owner="orders-controller",
        environment="staging",
        max_deletes=max_deletes,
    )


def _flow(
    flow_id: str, message: str = "hello", *, owner: str = "orders-controller"
) -> FlowDefinition:
    return _parse_flow(
        f"""id: {flow_id}
namespace: playground.orders.staging
labels:
  deployment.owner: {owner}
  system.readOnly: "true"
tasks:
  - id: log
    type: io.kestra.plugin.core.log.Log
    message: {message}
""",
        flow_id,
    )


class FakeKestraClient:
    def __init__(self, flows: tuple[FlowDefinition, ...] = ()) -> None:
        self.flows = {flow.id: flow for flow in flows}
        self.events: list[tuple[str, str]] = []
        self.fail_update: str | None = None

    def validate_flows(self, flows: tuple[FlowDefinition, ...]) -> None:
        self.events.append(("validate", ",".join(flow.id for flow in flows)))

    def list_flows(self, namespace: str) -> tuple[FlowDefinition, ...]:
        self.events.append(("list", namespace))
        return tuple(self.flows.values())

    def create_flow(self, flow: FlowDefinition) -> None:
        self.events.append(("create", flow.id))
        self.flows[flow.id] = flow

    def update_flow(self, flow: FlowDefinition) -> None:
        self.events.append(("update", flow.id))
        if self.fail_update == flow.id:
            raise ReconcileError("simulated update failure")
        self.flows[flow.id] = flow

    def delete_flow(self, namespace: str, flow_id: str) -> None:
        self.events.append(("delete", flow_id))
        del self.flows[flow_id]


def test_reconcile_creates_updates_deletes_then_verifies_exact_state(tmp_path: Path) -> None:
    desired = (_flow("create_me"), _flow("update_me", "new"), _flow("same"))
    client = FakeKestraClient((_flow("update_me", "old"), _flow("same"), _flow("delete_me")))

    plan = reconcile(client, _manifest(tmp_path), desired, apply=True, allow_delete=True)

    assert plan.as_dict() == {
        "create": ["create_me"],
        "update": ["update_me"],
        "delete": ["delete_me"],
        "unchanged": ["same"],
    }
    mutations = [event for event in client.events if event[0] in {"create", "update", "delete"}]
    assert mutations == [
        ("create", "create_me"),
        ("update", "update_me"),
        ("delete", "delete_me"),
    ]
    assert set(client.flows) == {"create_me", "update_me", "same"}


def test_second_apply_is_an_idempotent_no_op(tmp_path: Path) -> None:
    desired = (_flow("one"), _flow("two"))
    client = FakeKestraClient()
    manifest = _manifest(tmp_path)

    reconcile(client, manifest, desired, apply=True, allow_delete=True)
    client.events.clear()
    second = reconcile(client, manifest, desired, apply=True, allow_delete=True)

    assert second.create == second.update == second.delete == ()
    assert second.unchanged == ("one", "two")
    assert all(event[0] in {"validate", "list"} for event in client.events)


def test_failed_update_prevents_deletion(tmp_path: Path) -> None:
    desired = (_flow("update_me", "new"),)
    client = FakeKestraClient((_flow("update_me", "old"), _flow("delete_me")))
    client.fail_update = "update_me"

    with pytest.raises(ReconcileError, match="simulated update failure"):
        reconcile(client, _manifest(tmp_path), desired, apply=True, allow_delete=True)

    assert "delete_me" in client.flows
    assert ("delete", "delete_me") not in client.events


def test_apply_requires_explicit_delete_and_enforces_limit(tmp_path: Path) -> None:
    desired = (_flow("keep"),)
    client = FakeKestraClient((_flow("keep"), _flow("stale")))

    with pytest.raises(ReconcileError, match="--delete"):
        reconcile(client, _manifest(tmp_path), desired, apply=True, allow_delete=False)
    with pytest.raises(ReconcileError, match="maxDeletes=0"):
        reconcile(
            client,
            _manifest(tmp_path, max_deletes=0),
            desired,
            apply=False,
            allow_delete=False,
        )


def test_foreign_owner_blocks_namespace_management(tmp_path: Path) -> None:
    with pytest.raises(ReconcileError, match="Refusing to manage"):
        build_plan(_manifest(tmp_path), (_flow("desired"),), (_flow("foreign", owner="other"),))


def test_desired_directory_must_be_nonempty_and_within_boundary(tmp_path: Path) -> None:
    empty = tmp_path / "empty"
    empty.mkdir()
    with pytest.raises(ReconcileError, match="empty desired"):
        load_desired_flows(_manifest(empty))

    wrong_namespace = tmp_path / "wrong"
    wrong_namespace.mkdir()
    (wrong_namespace / "flow.yaml").write_text(
        """id: wrong
namespace: another.namespace
labels:
  deployment.owner: orders-controller
  system.readOnly: "true"
tasks: []
"""
    )
    with pytest.raises(ReconcileError, match="does not equal manifest namespace"):
        load_desired_flows(_manifest(wrong_namespace))


def test_http_client_uses_kestra_flow_api_for_exact_reconciliation(tmp_path: Path) -> None:
    state = {"stale": _flow("stale").source}
    requests: list[tuple[str, str]] = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            return

        def _body(self) -> str:
            return self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()

        def _json(self, value: object, status: int = 200) -> None:
            payload = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self) -> None:
            requests.append(("GET", self.path))
            assert self.headers["Authorization"].startswith("Basic ")
            if self.path == "/api/v1/main/flows/playground.orders.staging":
                self._json([{"id": flow_id} for flow_id in state])
                return
            flow_id = self.path.split("/")[-1].split("?")[0]
            self._json({"source": state[flow_id]})

        def do_POST(self) -> None:
            requests.append(("POST", self.path))
            body = self._body()
            if self.path.endswith("/validate"):
                self._json(
                    [
                        {"index": index, "constraints": None}
                        for index, _ in enumerate(body.split("\n---\n"))
                    ]
                )
                return
            flow = _parse_flow(body, "request")
            state[flow.id] = body
            self._json({"id": flow.id}, status=201)

        def do_DELETE(self) -> None:
            requests.append(("DELETE", self.path))
            del state[self.path.rsplit("/", 1)[1]]
            self.send_response(204)
            self.end_headers()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        client = KestraApiClient(
            f"http://127.0.0.1:{server.server_port}", "main", "user", "password"
        )
        plan = reconcile(
            client,
            _manifest(tmp_path),
            (_flow("created"),),
            apply=True,
            allow_delete=True,
        )
    finally:
        server.shutdown()
        thread.join()
        server.server_close()

    assert plan.create == ("created",)
    assert plan.delete == ("stale",)
    assert set(state) == {"created"}
    assert ("POST", "/api/v1/main/flows/validate") in requests
    assert ("DELETE", "/api/v1/main/flows/playground.orders.staging/stale") in requests
