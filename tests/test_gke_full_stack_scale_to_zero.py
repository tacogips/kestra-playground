"""Regression tests for the GKE PostgreSQL cutover and full-stack activator."""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def _read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_cloud_sql_cutover_is_backup_first_and_idempotent() -> None:
    script = _read_text("scripts/apply-gke-dev.sh")

    backup = script.index("gcloud sql backups create")
    quiesce_gke = script.index("quiesce_gke_kestra", backup)
    quiesce_gce = script.index("quiesce_gce_workers", quiesce_gke)
    migration_job = script.index("render_cloud_sql_migration_job", quiesce_gce)

    assert backup < quiesce_gke < quiesce_gce < migration_job
    assert "postgres_migration_complete" in script
    assert "_gke_cloud_sql_migration" in script
    assert (
        "Destination \\$database already has \\$existing_tables user tables; preserving it."
        in script
    )
    assert "GKE_POSTGRES_MIGRATE_FROM_CLOUD_SQL" in script
    assert "PostgreSQL StatefulSet did not become ready; collecting diagnostics." in script
    assert "describe pod -l app.kubernetes.io/name=kestra-postgres" in script


def test_cloud_sql_migration_uses_native_sidecar_and_retained_destination() -> None:
    script = _read_text("scripts/apply-gke-dev.sh")
    postgres = list(yaml.safe_load_all(_read_text("k8s/base/postgres.yaml")))
    statefulset = next(document for document in postgres if document["kind"] == "StatefulSet")

    assert "restartPolicy: Always" in script
    assert "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1" in script
    assert "pg_dump" in script
    assert "pg_restore" in script
    assert "--exit-on-error" in script
    assert statefulset["spec"]["persistentVolumeClaimRetentionPolicy"] == {
        "whenDeleted": "Retain",
        "whenScaled": "Retain",
    }


def test_terraform_keeps_explicit_migration_source_outputs() -> None:
    terraform = _read_text("infra/terraform/gke-dev/main.tf")

    assert 'output "legacy_cloud_sql_connection_name"' in terraform
    assert 'output "legacy_cloud_sql_instance_name"' in terraform
    assert 'resource "google_sql_database_instance" "postgres"' in terraform
    assert "Temporary migration source" in terraform


def test_cutover_starts_only_gce_instances_that_it_stopped() -> None:
    script = _read_text("scripts/apply-gke-dev.sh")

    assert 'cutover_stopped_instances+=("$instance")' in script
    assert 'for instance in "${cutover_stopped_instances[@]}"' in script
    assert '== "TERMINATED"' in script
    assert "gcloud compute instances start" in script


def test_routed_deployment_runs_full_stack_live_verification() -> None:
    workflow = yaml.safe_load(_read_text(".github/workflows/deploy.yml"))
    steps = workflow["jobs"]["deploy"]["steps"]
    verifier = next(
        step for step in steps if step["name"] == "Verify routed full-stack scale-to-zero"
    )

    assert verifier["if"] == "${{ inputs.target_environment == 'routed' }}"
    assert verifier["run"] == "nix develop -c scripts/verify-live-gke-full-stack-scale-to-zero.sh"


def test_live_verifier_uses_observed_readiness_and_reports_http_diagnostics() -> None:
    script = _read_text("scripts/verify-live-gke-full-stack-scale-to-zero.sh")

    assert "status.readyReplicas" in script
    assert "diagnose_http_failure" in script
    assert "http://kestra-webserver/" in script
    assert "logs deployment/kestra-webserver" in script
    assert "logs deployment/kestra-worker-activator" in script
