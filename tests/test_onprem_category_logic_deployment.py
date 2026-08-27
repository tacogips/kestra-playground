import re
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
    assert playbook["vars"]["container_runtime_executable"] == "podman"


def test_gce_workers_power_off_at_23_jst_without_a_catch_up_shutdown() -> None:
    startup = _read("infra/terraform/gke-dev/controller-worker-startup.sh.tftpl")

    assert "OnCalendar=*-*-* 23:00:00 Asia/Tokyo" in startup
    assert "ExecStart=/usr/bin/systemctl poweroff" in startup
    assert "systemctl enable --now kestra-worker-nightly-poweroff.timer" in startup
    assert "Persistent=true" not in startup


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
    assert "dev-local" in verifier
    assert "1.1.0" in verifier
    assert "9.9.0" in verifier
    assert "DEV main-push workflow" in verifier
    assert "STAGING tag workflow" in verifier
    assert verifier.count('"$inventory" orders_workers') >= 3
    assert "persist-category-logic-release.sh" in verifier
    assert "worker_a_before" in verifier
    assert "worker_a_after" in verifier
    assert "worker_b_before" in verifier
    assert "worker_b_after" in verifier
    assert "cold" not in verifier.lower()


def test_gcp_verifier_uses_low_cost_persistent_workers_and_stops_them() -> None:
    verifier = _read("scripts/verify-live-gcp-category-logic-ansible.sh")

    assert "GCP_CATEGORY_LOGIC_MACHINE_TYPE:-e2-small" in verifier
    assert "systemctl is-system-running" in verifier
    assert '"$state" == "running" || "$state" == "degraded"' in verifier
    assert '"$worker_container" docker' in verifier
    assert "GCP_STOP_AFTER_VERIFY:-true" in verifier
    assert 'gcloud compute instances stop "$instance_a" "$instance_b"' in verifier
    assert "kestra-worker-nightly-poweroff.timer" in verifier
    builder = _read("scripts/build-category-logic-bundle.sh")
    assert "linux/amd64" in builder
    assert "type=docker,dest=${archive_path}" in builder
    assert "type=oci,dest=${archive_path}" not in builder


def test_gcp_category_logic_flow_runs_deployed_image_on_both_workers() -> None:
    flow = yaml.safe_load(
        _read("kestra/flows-onprem/controller/verify_gcp_category_logic_deployment.yaml")
    )
    normal, special = flow["tasks"]

    assert normal["containerImage"] == "{{ inputs.logic_image }}"
    assert normal["taskRunner"] == {
        "type": "io.kestra.plugin.scripts.runner.docker.Docker",
        "host": "unix:///var/run/docker.sock",
        "pullPolicy": "NEVER",
    }
    assert normal["workerSelector"]["tags"] == ["gce-a"]
    assert special["workerSelector"]["tags"] == ["gce-b"]
    assert "/app/batches/version.sh" in normal["commands"][0]
    assert "/app/batches/normal_batch.sh" in normal["commands"][0]
    assert "/app/batches/special_batch.sh" in special["commands"][0]

    startup = _read("infra/terraform/gke-dev/controller-worker-startup.sh.tftpl")
    assert "/tmp/kestra-wd:/tmp/kestra-wd" in startup
    assert "/var/run/docker.sock:/var/run/docker.sock" in startup


def test_onprem_design_shows_server_contents_and_same_artifact_promotion() -> None:
    design = _read("design-docs/specs/design-onprem-category-logic-deployment.md")

    assert "flowchart LR" in design
    assert "sequenceDiagram" in design
    assert "Deployment server / self-hosted runner" in design
    assert "CURRENT DEV + STAGING: orders-worker-01..N" in design
    assert "PRODUCTION: prd-worker-01..N" in design
    assert "Web server: running, unchanged" in design
    assert "Kestra worker: running, unchanged" in design
    assert "deploy the same stored archive" in design
    assert "/var/lib/kestra-releases/<category>/<version>/" in design


def test_dev_and_staging_workflows_deploy_to_the_same_configurable_inventory() -> None:
    dev_text = _read(".github/workflows/deploy-category-logic-dev.yml")
    dev = yaml.load(dev_text, Loader=yaml.BaseLoader)
    staging = yaml.load(
        _read(".github/workflows/deploy-category-logic-staging.yml"), Loader=yaml.BaseLoader
    )

    assert dev["on"]["push"]["branches"] == ["main"]
    assert "examples/category-batch-image/**" in dev["on"]["push"]["paths"]
    assert "kestra/flows-onprem/controller/**" not in dev["on"]["push"]["paths"]
    assert staging["on"]["push"]["tags"] == ["orders-v*"]
    assert dev["jobs"]["deploy"]["environment"]["name"] == "development"
    assert staging["jobs"]["deploy"]["environment"]["name"] == "staging"
    assert dev["jobs"]["deploy"]["runs-on"] == ["self-hosted", "onprem", "category-deploy"]
    assert staging["jobs"]["deploy"]["runs-on"] == [
        "self-hosted",
        "onprem",
        "category-deploy",
    ]
    for variable in ["CATEGORY_LOGIC_INVENTORY", "CATEGORY_LOGIC_TARGET_GROUP"]:
        assert dev["jobs"]["deploy"]["env"][variable] == "${{ vars." + variable + " }}"
        assert staging["jobs"]["deploy"]["env"][variable] == "${{ vars." + variable + " }}"

    staging_text = _read(".github/workflows/deploy-category-logic-staging.yml")
    assert "persist-category-logic-release.sh" in staging_text
    assert "git merge-base --is-ancestor" in staging_text
    assert "docker/setup-buildx-action@37fe631027851001ddb9b187196cc803df7f5f0e" in dev_text
    assert "docker/setup-buildx-action@37fe631027851001ddb9b187196cc803df7f5f0e" in staging_text


def test_controller_tag_deploys_flows_and_checks_runtime_continuity() -> None:
    workflow_text = _read(".github/workflows/deploy-category-controller.yml")
    workflow = yaml.load(workflow_text, Loader=yaml.BaseLoader)
    deploy_script = _read("scripts/deploy-category-controller-flows.sh")

    assert workflow["on"]["push"]["tags"] == ["orders-controller-v*"]
    assert "^orders-controller-v[0-9]+\\.[0-9]+\\.[0-9]+$" in workflow_text
    assert "git merge-base --is-ancestor" in workflow_text
    assert workflow["jobs"]["deploy"]["environment"]["name"] == "development"
    assert workflow["jobs"]["deploy"]["permissions"] == {
        "contents": "read",
        "id-token": "write",
    }
    assert "deploy-category-controller-flows.sh" in workflow_text

    assert 'flow_directory="${2:-kestra/flows-onprem/controller}"' in deploy_script
    assert 'scripts/register-flows.sh "$kestra_url" "$flow_directory"' in deploy_script
    assert "/api/v1/main/flows/${flow_namespace}/${flow_id}" in deploy_script
    assert "controller_snapshot" in deploy_script
    assert "external_worker_snapshot" in deploy_script
    assert "require_expected_external_workers" in deploy_script
    assert "restartCount" in deploy_script
    assert "lastStartTimestamp" in deploy_script
    assert "rollout restart" not in deploy_script
    assert "ansible" not in deploy_script.lower()

    oidc_variables = _read("infra/terraform/github-actions/variables.tf")
    assert '"orders-controller-v"' in oidc_variables


def test_ansible_core_is_pinned_for_self_hosted_deployment() -> None:
    mise = _read("mise.toml")

    assert '"pipx:ansible-core" = "2.21.3"' in mise
    assert "uvx --from 'ansible-core==2.21.3'" in _read("scripts/deploy-category-logic-ansible.sh")


def test_category_logic_workflows_follow_action_security_baseline() -> None:
    for path in [
        ".github/workflows/deploy-category-logic-dev.yml",
        ".github/workflows/deploy-category-logic-staging.yml",
    ]:
        workflow_text = _read(path)
        workflow = yaml.load(workflow_text, Loader=yaml.BaseLoader)

        assert workflow["permissions"] == {"contents": "read"}
        assert workflow["concurrency"]["cancel-in-progress"] == "false"
        assert "${{ github.event." not in workflow_text
        for job in workflow["jobs"].values():
            assert job["timeout-minutes"]
            assert job["permissions"] == {"contents": "read"}
        for action_reference in re.findall(r"uses:\s*([^\s]+)", workflow_text):
            assert re.search(r"@[0-9a-f]{40}$", action_reference)

    controller_text = _read(".github/workflows/deploy-category-controller.yml")
    controller = yaml.load(controller_text, Loader=yaml.BaseLoader)
    assert controller["permissions"] == {"contents": "read"}
    assert controller["concurrency"]["cancel-in-progress"] == "false"
    for job in controller["jobs"].values():
        assert job["timeout-minutes"]
    for action_reference in re.findall(r"uses:\s*([^\s]+)", controller_text):
        assert re.search(r"@[0-9a-f]{40}$", action_reference)
