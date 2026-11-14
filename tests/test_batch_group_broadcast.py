"""Regression tests for the routed batch-group broadcast demonstration."""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_broadcast_flow_targets_the_entire_gke_small_group() -> None:
    flow = yaml.safe_load(
        (ROOT / "kestra/flows-worker-routing/verify_batch_group_broadcast.yaml").read_text(
            encoding="utf-8"
        )
    )

    assert flow["id"] == "verify_batch_group_broadcast"
    assert len(flow["tasks"]) == 1

    task = flow["tasks"][0]
    assert task["id"] == "broadcast_to_batch_group"
    assert task["taskRunner"] == {"type": "io.kestra.plugin.core.runner.Process"}
    assert task["workerSelector"] == {
        "tags": ["gke-small"],
        "match": "ALL",
        "fallback": "FAIL",
        "broadcast": True,
    }
    assert "batch_group_member=" in task["commands"][0]


def test_live_broadcast_verifier_checks_members_and_aggregated_outputs() -> None:
    script = (ROOT / "scripts/verify-live-batch-group-broadcast.sh").read_text(encoding="utf-8")

    assert 'EXPECTED_WORKERS="${BROADCAST_WORKER_REPLICAS:-2}"' in script
    assert "restore_worker_replicas" in script
    assert "trap restore_worker_replicas EXIT" in script
    assert "rollout restart deployment/" in script
    assert "wait_for_worker_registrations" in script
    assert 'grep -F "Connected to controller:"' in script
    assert "select(.metadata.deletionTimestamp == null)" in script
    assert "/api/v1/main/outputs/${execution_id}/${task_run_id}" in script
    assert "output_worker_count" in script
    assert "batch_group_member=" in script


def test_local_broadcast_topology_uses_latest_routing_property() -> None:
    config = yaml.safe_load((ROOT / "local/broadcast/application.yaml").read_text(encoding="utf-8"))
    routing = config["kestra"]["worker"]["routing"]

    assert "groups" not in routing
    assert routing["groupQueueMappings"]["broadcast-batch"]["queues"] == [
        {"workerQueueId": "gke-small", "reservedPercent": -1}
    ]
    assert routing["queues"]["gke-small"]["tags"] == ["gke-small"]


def test_local_broadcast_verifier_requires_two_members_and_outputs() -> None:
    script = (ROOT / "scripts/verify-local-batch-group-broadcast.sh").read_text(encoding="utf-8")

    assert "KESTRA_WORKER_GROUP_ID=broadcast-batch" in script
    assert 'POD_NAME="${member_name}"' in script
    assert "EXPECTED_WORKERS=2" in script
    assert "/api/v1/main/outputs/${execution_id}/${task_run_id}" in script
    assert '"${members[*]}" != "batch-worker-a batch-worker-b"' in script


def test_routed_image_uses_the_merged_broadcast_revision() -> None:
    workflow = yaml.safe_load((ROOT / ".github/workflows/deploy.yml").read_text(encoding="utf-8"))
    routed_env = workflow["jobs"]["build-routed-image"]["env"]

    assert routed_env["KESTRA_SOURCE_REF"] == "96e1be9b4b1ff88cbac11dbd0b5280a3445f7e2b"
