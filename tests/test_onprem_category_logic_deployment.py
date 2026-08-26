from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def _read(path: str) -> str:
    return (ROOT / path).read_text()


def test_category_image_exposes_immutable_version_metadata_and_task() -> None:
    dockerfile = _read("examples/category-batch-image/Dockerfile")
    version_task = _read("examples/category-batch-image/batches/version.sh")

    assert "ARG LOGIC_VERSION" in dockerfile
    assert 'org.opencontainers.image.version="${LOGIC_VERSION}"' in dockerfile
    assert 'org.opencontainers.image.revision="${REVISION}"' in dockerfile
    assert '"category":"%s","version":"%s","revision":"%s"' in version_task


def test_deploy_targets_only_inventory_group_and_proves_worker_continuity() -> None:
    playbook = yaml.safe_load(_read("ops/ansible/category-logic/deploy.yml"))[0]
    serialized = yaml.safe_dump(playbook)

    assert playbook["hosts"] == "{{ target_group }}"
    assert playbook["any_errors_fatal"] is True
    assert "load" in serialized
    assert "logic_archive_sha256" in serialized
    assert "worker_after.Id == worker_before.Id" in serialized
    assert "worker_after.State.StartedAt == worker_before.State.StartedAt" in serialized
    assert "- restart" not in serialized
    assert "ansible.builtin.service" not in serialized


def test_periodic_flow_broadcasts_version_probe_to_every_selected_worker() -> None:
    flow = yaml.safe_load(_read("kestra/flows-onprem/monitor_category_logic_versions.yaml"))
    task = flow["tasks"][0]
    selector = task["workerSelector"]

    assert task["taskRunner"]["type"] == "io.kestra.plugin.core.runner.Process"
    assert selector == {
        "tags": ["onprem-orders"],
        "match": "ALL",
        "fallback": "FAIL",
        "broadcast": True,
    }
    assert flow["triggers"][0]["cron"] == "*/5 * * * *"
    assert "/app/batches/version.sh" in task["commands"][0]


def test_local_verifier_deploys_two_versions_to_two_hosts_without_cold_start() -> None:
    verifier = _read("scripts/verify-local-category-logic-ansible.sh")

    assert "host_a=" in verifier
    assert "host_b=" in verifier
    assert "1.0.0" in verifier
    assert "1.1.0" in verifier
    assert "9.9.0" in verifier
    assert "worker_a_before" in verifier
    assert "worker_a_after" in verifier
    assert "worker_b_before" in verifier
    assert "worker_b_after" in verifier
    assert "cold" not in verifier.lower()
