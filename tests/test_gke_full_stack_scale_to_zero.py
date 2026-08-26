"""Regression tests for the GKE PostgreSQL cutover and full-stack activator."""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def _read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_gke_apply_no_longer_contains_the_completed_cloud_sql_migration() -> None:
    script = _read_text("scripts/apply-gke-dev.sh")

    assert "gcloud sql backups create" not in script
    assert "cloud-sql-proxy" not in script
    assert "GKE_POSTGRES_MIGRATE_FROM_CLOUD_SQL" not in script
    assert "PostgreSQL StatefulSet did not become ready; collecting diagnostics." in script
    assert "describe pod -l app.kubernetes.io/name=kestra-postgres" in script


def test_postgres_statefulset_retains_its_destination_volume() -> None:
    postgres = list(yaml.safe_load_all(_read_text("k8s/base/postgres.yaml")))
    statefulset = next(document for document in postgres if document["kind"] == "StatefulSet")

    assert statefulset["spec"]["persistentVolumeClaimRetentionPolicy"] == {
        "whenDeleted": "Retain",
        "whenScaled": "Retain",
    }


def test_gke_terraform_removes_the_legacy_cloud_sql_source() -> None:
    terraform = _read_text("infra/terraform/gke-dev/main.tf")
    variables = _read_text("infra/terraform/gke-dev/variables.tf")

    assert "google_sql_" not in terraform
    assert "cloudsql_client" not in terraform
    assert "legacy_cloud_sql" not in terraform
    assert 'variable "sql_tier"' not in variables


def test_finalization_creates_portable_backups_before_deploying_removal() -> None:
    finalizer = _read_text("scripts/finalize-live-gke-postgres.sh")
    backup = _read_text("scripts/backup-live-gke-postgres.sh")

    backup_step = finalizer.index("scripts/backup-live-gke-postgres.sh")
    untrack_owner = finalizer.index("state rm google_sql_user.kestra")
    deploy_step = finalizer.index("scripts/deploy-routed-live.sh")

    assert backup_step < untrack_owner < deploy_step
    assert "pg_dump" in backup
    assert "kestra ecommerce_ops" in backup
    assert "gcloud storage cp" in backup
    assert "PostgreSQL backup for ${database} is empty." in backup


def test_activator_accepts_whitespace_in_kubernetes_json() -> None:
    script = _read_text("scripts/apply-gke-dev.sh")

    assert '"readyReplicas":[[:space:]]*1' in script
    assert '"(availableReplicas|readyReplicas|replicas)":[[:space:]]*([1-9][0-9]*)' in script


def test_routed_deployment_runs_full_stack_live_verification() -> None:
    workflow = yaml.safe_load(_read_text(".github/workflows/deploy.yml"))
    steps = workflow["jobs"]["deploy"]["steps"]
    verifier = next(
        step for step in steps if step["name"] == "Verify routed full-stack scale-to-zero"
    )

    assert verifier["if"] == "${{ inputs.target_environment == 'routed' }}"
    assert verifier["run"] == "mise exec -- scripts/verify-live-gke-full-stack-scale-to-zero.sh"


def test_live_verifier_uses_observed_readiness_and_reports_http_diagnostics() -> None:
    script = _read_text("scripts/verify-live-gke-full-stack-scale-to-zero.sh")

    assert "2?? | 3?? | 401 | 502 | 503 | 504" in script
    assert "status.readyReplicas" in script
    assert "ensure_gke_kubectl_auth" in script
    assert "diagnose_http_failure" in script
    assert "StatefulSet ${statefulset} did not report one ready replica." in script
    assert script.count("diagnose_http_failure") >= 3
    assert "http://kestra-webserver/" in script
    assert "logs statefulset/kestra-webserver" in script
    assert "logs deployment/kestra-worker-activator" in script


def test_workflow_supports_verification_without_rebuilding_or_redeploying() -> None:
    workflow = yaml.safe_load(_read_text(".github/workflows/deploy.yml"))
    verify_job = workflow["jobs"]["verify-routed"]

    assert (
        "routed-verify"
        in workflow[True]["workflow_dispatch"]["inputs"]["target_environment"]["options"]
    )
    assert "inputs.target_environment == 'routed-verify'" in verify_job["if"]
    assert verify_job["permissions"] == {"contents": "read", "id-token": "write"}
    assert "inputs.target_environment != 'routed-verify'" in workflow["jobs"]["build-image"]["if"]
    assert "inputs.target_environment != 'routed-verify'" in workflow["jobs"]["deploy"]["if"]


def test_workflow_supports_short_routed_diagnostics() -> None:
    workflow = yaml.safe_load(_read_text(".github/workflows/deploy.yml"))
    diagnose_job = workflow["jobs"]["diagnose-routed"]

    assert (
        "routed-diagnose"
        in workflow[True]["workflow_dispatch"]["inputs"]["target_environment"]["options"]
    )
    assert "inputs.target_environment == 'routed-diagnose'" in diagnose_job["if"]
    assert diagnose_job["permissions"] == {"contents": "read", "id-token": "write"}
    assert "inputs.target_environment != 'routed-diagnose'" in workflow["jobs"]["build-image"]["if"]
    assert "inputs.target_environment != 'routed-diagnose'" in workflow["jobs"]["deploy"]["if"]


def test_workflow_can_refresh_and_verify_the_routed_activator() -> None:
    workflow = yaml.safe_load(_read_text(".github/workflows/deploy.yml"))
    refresh_job = workflow["jobs"]["refresh-routed"]

    assert (
        "routed-refresh"
        in workflow[True]["workflow_dispatch"]["inputs"]["target_environment"]["options"]
    )
    assert "inputs.target_environment == 'routed-refresh'" in refresh_job["if"]
    assert refresh_job["permissions"] == {"contents": "read", "id-token": "write"}
    assert "inputs.target_environment != 'routed-refresh'" in workflow["jobs"]["build-image"]["if"]
    assert "inputs.target_environment != 'routed-refresh'" in workflow["jobs"]["deploy"]["if"]


def test_workflow_can_finalize_and_verify_the_postgres_cutover() -> None:
    workflow = yaml.safe_load(_read_text(".github/workflows/deploy.yml"))
    finalize_job = workflow["jobs"]["finalize-routed"]

    assert (
        "routed-finalize"
        in workflow[True]["workflow_dispatch"]["inputs"]["target_environment"]["options"]
    )
    assert "inputs.target_environment == 'routed-finalize'" in finalize_job["if"]
    assert finalize_job["permissions"] == {"contents": "read", "id-token": "write"}
    assert "inputs.target_environment != 'routed-finalize'" in workflow["jobs"]["build-image"]["if"]
    assert "inputs.target_environment != 'routed-finalize'" in workflow["jobs"]["deploy"]["if"]
