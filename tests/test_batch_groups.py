"""Tests for the two-batch-group (EC / affiliate) source layout and deploys."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).parent.parent


def _load_yaml(path: str) -> dict[Any, Any]:
    return yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))


def _read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def _load_env(path: str) -> dict[str, str]:
    entries: dict[str, str] = {}
    for line in _read_text(path).splitlines():
        if line == "" or line.startswith("#"):
            continue
        key, value = line.split("=", maxsplit=1)
        entries[key] = value
    return entries


def _run_batch(
    script: Path, config: dict[str, object], output_path: Path
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["KESTRA_BATCH_CONFIG"] = json.dumps(config)
    env["KESTRA_BATCH_OUTPUT"] = str(output_path)
    return subprocess.run(
        [sys.executable, str(script)],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def test_each_system_manages_its_own_flow_and_batch_sources() -> None:
    for system in ("ec", "affiliate"):
        assert (ROOT / f"batch-groups/{system}/flows").is_dir()
        assert (ROOT / f"batch-groups/{system}/batches").is_dir()
        assert list((ROOT / f"batch-groups/{system}/flows").glob("*.yaml"))


def test_ec_flows_stay_in_the_ecommerce_namespace() -> None:
    for flow_path in sorted((ROOT / "batch-groups/ec/flows").glob("*.yaml")):
        flow = yaml.safe_load(flow_path.read_text(encoding="utf-8"))
        assert flow["namespace"] == "playground.ecommerce", flow_path


def test_affiliate_flows_stay_in_the_affiliate_namespace() -> None:
    flow_ids = []
    for flow_path in sorted((ROOT / "batch-groups/affiliate/flows").glob("*.yaml")):
        flow = yaml.safe_load(flow_path.read_text(encoding="utf-8"))
        assert flow["namespace"] == "playground.affiliate", flow_path
        assert flow["labels"]["domain"] == "affiliate"
        flow_ids.append(flow["id"])

    assert flow_ids == [
        "build_affiliate_daily_report",
        "build_affiliate_partner_rankings",
        "generate_affiliate_mock_data",
    ]


def test_affiliate_flows_use_the_shared_batch_database() -> None:
    for flow_path in sorted((ROOT / "batch-groups/affiliate/flows").glob("*.yaml")):
        flow = yaml.safe_load(flow_path.read_text(encoding="utf-8"))
        defaults = {entry["type"]: entry["values"] for entry in flow["pluginDefaults"]}
        values = defaults["io.kestra.plugin.jdbc.postgresql"]

        assert values["url"] == "{{ envs.batch_db_url }}"
        assert values["username"] == "{{ envs.batch_db_username }}"
        assert values["password"] == "{{ envs.batch_db_password }}"


def test_affiliate_mock_data_flow_is_split_into_granular_tasks() -> None:
    flow = _load_yaml("batch-groups/affiliate/flows/generate_affiliate_mock_data.yaml")

    assert [task["id"] for task in flow["tasks"]] == [
        "create_tables",
        "seed_partners",
        "purge_daily_activity",
        "insert_clicks",
        "insert_conversions",
        "summarize_generated_data",
    ]


def test_local_compose_runs_both_batch_groups_against_one_postgres() -> None:
    compose = _load_yaml("local/docker/docker-compose.yml")
    services = compose["services"]

    assert "postgres" in services
    ec = services["kestra-ec"]
    affiliate = services["kestra-affiliate"]

    assert ec["depends_on"]["postgres"]["condition"] == "service_healthy"
    assert affiliate["depends_on"]["postgres"]["condition"] == "service_healthy"

    assert ec["env_file"] == ["../../batch-groups/ec/config/envs/local.env"]
    assert affiliate["env_file"] == ["../../batch-groups/affiliate/config/envs/local.env"]

    assert "8080:8080" in ec["ports"]
    assert "8082:8080" in affiliate["ports"]

    assert (
        "../../batch-groups/ec/batches:/app/kestra-playground/batch-groups/ec/batches:ro"
        in ec["volumes"]
    )
    assert (
        "../../batch-groups/affiliate/batches:/app/kestra-playground/batch-groups/affiliate/batches:ro"
        in affiliate["volumes"]
    )


def test_affiliate_local_kestra_defaults_to_the_official_image() -> None:
    compose = _load_yaml("local/docker/docker-compose.yml")

    assert compose["services"]["kestra-affiliate"]["image"] == (
        "${AFFILIATE_KESTRA_IMAGE:-kestra/kestra:latest}"
    )


def test_batch_group_env_files_are_owned_separately() -> None:
    shared = _load_env("local/docker/.env.example")
    ec = _load_env("batch-groups/ec/config/envs/local.env.example")
    affiliate = _load_env("batch-groups/affiliate/config/envs/local.env.example")
    ec_gcp = _load_env("batch-groups/ec/config/envs/gcp.env.example")
    affiliate_gcp = _load_env("batch-groups/affiliate/config/envs/gcp.env.example")

    assert set(shared) == {
        "POSTGRES_DB",
        "POSTGRES_USER",
        "POSTGRES_PASSWORD",
        "BATCH_DB",
        "BATCH_DB_USER",
        "BATCH_DB_PASSWORD",
        "AFFILIATE_KESTRA_DB",
    }
    assert ec["KESTRA_URL"] == "http://localhost:8080/"
    assert ec["KESTRA_DB_URL"].endswith("/kestra")
    assert affiliate["KESTRA_URL"] == "http://localhost:8082/"
    assert affiliate["KESTRA_DB_URL"].endswith("/kestra_affiliate")
    assert ec["ENV_BATCH_DB_URL"] == affiliate["ENV_BATCH_DB_URL"]
    assert ec_gcp == {
        "LIVE_KESTRA_SUBDOMAIN": "k8s",
        "KESTRA_AUTH_SECRET_PREFIX": "kestra-dev-gke",
        "KESTRA_AUTH_SOURCE": "secret-manager",
    }
    assert affiliate_gcp == {
        "LIVE_KESTRA_SUBDOMAIN": "affiliate-kestra",
        "KESTRA_AUTH_SECRET_PREFIX": "kestra-affiliate",
        "KESTRA_AUTH_SOURCE": "secret-manager",
    }
    assert not (ROOT / "kestra/config/envs/local.env.example").exists()


def test_local_env_provisions_the_affiliate_metadata_database() -> None:
    init_script = _read_text("local/docker/init-batch-db.sh")
    start_script = _read_text("local/docker/start.sh")

    assert "AFFILIATE_KESTRA_DB" in init_script
    assert "CREATE DATABASE ${AFFILIATE_KESTRA_DB}" in init_script
    assert "CREATE DATABASE ${AFFILIATE_KESTRA_DB}" in start_script
    env_text = _read_text("local/docker/.env.example")
    assert "AFFILIATE_KESTRA_DB=kestra_affiliate" in env_text
    affiliate_env = _load_env("batch-groups/affiliate/config/envs/local.env.example")
    assert affiliate_env["KESTRA_DB_URL"] == (
        "jdbc:postgresql://kestra-postgres:5432/kestra_affiliate"
    )


def test_local_launchers_load_each_batch_group_env_file() -> None:
    docker_start = _read_text("local/docker/start.sh")
    apple_start = _read_text("local/apple-container/start.sh")

    for script in (docker_start, apple_start):
        assert 'batch-groups/ec/config/envs/local.env"' in script
        assert 'batch-groups/affiliate/config/envs/local.env"' in script

    assert '--env-file "${EC_ENV_FILE}"' in apple_start
    assert '--env-file "${AFFILIATE_ENV_FILE}"' in apple_start
    assert "grep -Ev" not in apple_start


def test_batch_group_deploy_workflow_routes_by_tag_prefix_and_main_diff() -> None:
    workflow = _load_yaml(".github/workflows/deploy-batch-groups.yml")
    push = workflow[True]["push"]

    assert push["branches"] == ["main"]
    assert push["tags"] == ["EC-*", "AFFILIATE-*"]

    resolve_run = workflow["jobs"]["resolve"]["steps"][-1]["run"]
    assert "^EC-[0-9]+\\.[0-9]+\\.[0-9]+$" in resolve_run
    assert "^AFFILIATE-[0-9]+\\.[0-9]+\\.[0-9]+$" in resolve_run
    assert "^batch-groups/ec/" in resolve_run
    assert "^batch-groups/affiliate/" in resolve_run
    assert "\\.md$" in resolve_run

    assert workflow["jobs"]["deploy-ec"]["if"] == (
        "${{ needs.resolve.outputs.deploy_ec == 'true' }}"
    )
    assert workflow["jobs"]["deploy-affiliate"]["if"] == (
        "${{ needs.resolve.outputs.deploy_affiliate == 'true' }}"
    )
    assert "scripts/deploy-batch-group.sh ec" in (workflow["jobs"]["deploy-ec"]["steps"][-1]["run"])
    assert (
        "scripts/deploy-batch-group.sh affiliate"
        in (workflow["jobs"]["deploy-affiliate"]["steps"][-1]["run"])
    )


def test_batch_group_deploy_script_maps_groups_to_flow_directories() -> None:
    script = _read_text("scripts/deploy-batch-group.sh")

    assert 'FLOW_DIR="batch-groups/ec/flows"' in script
    assert 'FLOW_DIR="batch-groups/affiliate/flows"' in script
    assert "batch-groups/${SYSTEM}/config/envs/${ENVIRONMENT}.env" in script
    assert 'ENVIRONMENT="${BATCH_GROUP_ENVIRONMENT:-}"' in script
    assert 'source "${ENV_FILE}"' in script

    result = subprocess.run(
        ["scripts/deploy-batch-group.sh", "unknown-system"],
        check=False,
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    assert result.returncode == 1
    assert "Unknown batch group: unknown-system" in result.stderr


def test_affiliate_conversion_aggregation_writes_summary(tmp_path: Path) -> None:
    output_path = tmp_path / "summary.json"
    result = _run_batch(
        ROOT / "batch-groups/affiliate/batches/conversion_stats/aggregate_conversions.py",
        {
            "input_path": str(
                ROOT / "batch-groups/affiliate/batches/conversion_stats/fixtures/conversions.jsonl"
            ),
            "business_date": "2026-06-25",
        },
        output_path,
    )

    assert result.returncode == 0, result.stderr
    assert "progress phase=complete" in result.stdout
    assert '"approved_commission_total"' in result.stdout

    summary = json.loads(output_path.read_text(encoding="utf-8"))
    assert summary["business_date"] == "2026-06-25"
    assert summary["matched_events"] == 7
    assert summary["malformed_events"] == 2
    assert summary["conversions_by_status"] == {"approved": 5, "pending": 1, "rejected": 1}
    assert summary["approved_commission_total"] == 85.5
    assert summary["commission_by_partner"] == {
        "AFP-0001": 42.5,
        "AFP-0002": 14.4,
        "AFP-0004": 21.0,
        "AFP-0005": 7.6,
    }


def test_affiliate_conversion_aggregation_rejects_missing_input(tmp_path: Path) -> None:
    result = _run_batch(
        ROOT / "batch-groups/affiliate/batches/conversion_stats/aggregate_conversions.py",
        {"input_path": str(tmp_path / "missing.jsonl"), "business_date": "2026-06-25"},
        tmp_path / "summary.json",
    )

    assert result.returncode == 64
    assert "batch_error type=FileNotFoundError" in result.stderr
