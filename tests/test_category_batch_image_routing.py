"""Regression tests for the category batch image routing example."""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def _read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_only_special_batch_selects_the_dedicated_worker() -> None:
    flow = yaml.safe_load(
        _read_text("kestra/flows-worker-routing/verify_category_batch_image_routing.yaml")
    )
    tasks = flow["tasks"][0]["tasks"]

    assert [task["id"] for task in tasks] == [
        "normal_batch_on_category_worker",
        "special_batch_on_dedicated_worker",
    ]
    assert "workerSelector" not in tasks[0]
    assert tasks[1]["workerSelector"] == {
        "tags": ["gke-large"],
        "match": "ALL",
        "fallback": "WAIT",
        "broadcast": False,
    }
    assert {task["spec"]["containers"][0]["image"] for task in tasks} == {
        "{{ envs.category_batch_image }}"
    }
    assert [task["spec"]["containers"][0]["command"] for task in tasks] == [
        ["/app/batches/normal_batch.sh"],
        ["/app/batches/special_batch.sh"],
    ]


def test_category_image_contains_both_batch_entrypoints() -> None:
    dockerfile = _read_text("examples/category-batch-image/Dockerfile")

    assert "COPY batches/ /app/batches/" in dockerfile
    assert 'ENV IMAGE_REVISION="${REVISION}"' in dockerfile
    assert "category=orders batch=normal target=default-worker" in _read_text(
        "examples/category-batch-image/batches/normal_batch.sh"
    )
    assert "category=orders batch=special target=dedicated-worker" in _read_text(
        "examples/category-batch-image/batches/special_batch.sh"
    )


def test_routed_workflow_publishes_and_deploys_the_sha_tagged_category_image() -> None:
    workflow = yaml.safe_load(_read_text(".github/workflows/deploy.yml"))
    build_job = workflow["jobs"]["build-routed-image"]
    deploy_job = workflow["jobs"]["deploy"]
    build_step = next(
        step for step in build_job["steps"] if step["name"] == "Build and push category batch image"
    )
    verify_step = next(
        step
        for step in deploy_job["steps"]
        if step["name"] == "Verify category batch image routing"
    )

    assert build_job["outputs"]["category_image"] == "${{ steps.category-image.outputs.image }}"
    assert 'IMAGE="${CATEGORY_IMAGE_REPOSITORY}:${GITHUB_SHA}"' in build_step["run"]
    assert "--platform linux/amd64,linux/arm64" in build_step["run"]
    assert deploy_job["env"]["CATEGORY_BATCH_IMAGE"] == (
        "${{ inputs.target_environment == 'routed' && "
        "needs.build-routed-image.outputs.category_image || '' }}"
    )
    assert verify_step == {
        "name": "Verify category batch image routing",
        "if": "${{ inputs.target_environment == 'routed' }}",
        "run": "mise exec -- scripts/verify-live-category-batch-image-routing.sh",
    }


def test_gke_runtime_exposes_the_category_image_to_flows() -> None:
    apply_script = _read_text("scripts/apply-gke-dev.sh")
    verifier = _read_text("scripts/verify-live-category-batch-image-routing.sh")

    assert 'category_batch_image="${CATEGORY_BATCH_IMAGE:-${kestra_image}}"' in apply_script
    assert 'ENV_CATEGORY_BATCH_IMAGE: "${category_batch_image}"' in apply_script
    assert "normal_batch_on_category_worker" in verifier
    assert "special_batch_on_dedicated_worker" in verifier
    assert 'if [[ "$normal_worker" == "$special_worker" ]]' in verifier
    assert "ENV_CATEGORY_BATCH_IMAGE | @base64d" in verifier
    assert "workerGroup=controller" in verifier
    assert "$'default\\nsystem'" in verifier
    assert "workerGroup=gke-large" in verifier


def test_worker_local_handoff_routes_both_tasks_to_one_stateful_worker() -> None:
    flow = yaml.safe_load(
        _read_text("kestra/flows-worker-routing/verify_worker_local_file_handoff.yaml")
    )
    tasks = flow["tasks"]

    assert flow["inputs"][0]["type"] == "BOOL"
    expected_selector = {
        "tags": ["gke-large"],
        "match": "ALL",
        "fallback": "WAIT",
        "broadcast": False,
    }
    assert [task["workerSelector"] for task in tasks] == [expected_selector] * 3
    assert all(
        task["taskRunner"]["type"] == "io.kestra.plugin.core.runner.Process" for task in tasks[:2]
    )
    assert "/var/lib/kestra-worker-local/{{ execution.id }}.txt" in tasks[0]["commands"][0]
    assert 'if [ ! -f "$path" ]' in tasks[1]["commands"][0]
    assert "exit 42" in tasks[1]["commands"][0]
    assert '::{"outputs":{"handoff_value":"%s"}}::' in tasks[1]["commands"][0]
    assert tasks[2]["id"] == "register_worker_local_file"
    assert tasks[2]["type"] == "io.kestra.plugin.jdbc.postgresql.Queries"
    assert tasks[2]["url"] == "{{ envs.batch_db_url }}"
    assert tasks[2]["username"] == "{{ envs.batch_db_username }}"
    assert tasks[2]["password"] == "{{ envs.batch_db_password }}"
    assert "CREATE TABLE IF NOT EXISTS worker_local_handoffs" in tasks[2]["sql"]
    assert "{{ outputs.read_worker_local_file.vars.handoff_value }}" in tasks[2]["sql"]


def test_gke_workers_are_statefulsets_with_retained_local_volumes() -> None:
    values = yaml.safe_load(_read_text("k8s/helm/kestra-values.yaml"))
    runtime_config = yaml.safe_load(_read_text("k8s/base/configmap.yaml"))
    apply_script = _read_text("scripts/apply-gke-dev.sh")

    assert values["common"]["kind"] == "StatefulSet"
    assert values["deployments"]["worker"]["autoscaler"]["enabled"] is False
    assert (
        runtime_config["data"]["application.yaml"]
        .split("routing:", 1)[1]
        .lstrip()
        .startswith("workerGroupId: controller")
    )
    assert "kind: StatefulSet" in apply_script
    assert "persistentVolumeClaimRetentionPolicy:" in apply_script
    assert "fsGroup: 1000" in apply_script
    assert "mountPath: /var/lib/kestra-worker-local" in apply_script
    assert "volumeClaimTemplates:" in apply_script
    assert "serviceName: kestra-gke-worker-${group_id#gke-}" in apply_script


def test_live_workflow_verifies_success_and_missing_file_cases() -> None:
    workflow = yaml.safe_load(_read_text(".github/workflows/deploy.yml"))
    verifier = _read_text("scripts/verify-live-worker-local-file-handoff.sh")
    verify_step = next(
        step
        for step in workflow["jobs"]["deploy"]["steps"]
        if step["name"] == "Verify worker-local file handoff"
    )

    assert verify_step["if"] == "${{ inputs.target_environment == 'routed' }}"
    assert verify_step["run"] == "mise exec -- scripts/verify-live-worker-local-file-handoff.sh"
    assert "wait_for_execution_state" in verifier
    assert "ensure_gke_kubectl_auth" in verifier
    assert '"$missing_id" FAILED' in verifier
    assert "worker-local-kestra-gke-worker-large-0" in verifier
    assert "workerGroup=gke-large" in verifier
    assert "SELECT handoff_value FROM worker_local_handoffs" in verifier
    assert "SELECT count(*) FROM worker_local_handoffs" in verifier
    assert any(
        step.get("run") == "mise exec -- scripts/verify-live-worker-local-file-handoff.sh"
        for step in workflow["jobs"]["verify-routed"]["steps"]
    )
