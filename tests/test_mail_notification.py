"""Tests for the mail notification flows and their mock-mailer wiring."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).parent.parent


def _load_yaml(path: str) -> dict[Any, Any]:
    return yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))


def _task_ids(tasks: list[dict[str, Any]]) -> list[str]:
    return [task["id"] for task in tasks]


def test_kestra2_notifier_uses_states_and_when_instead_of_conditions() -> None:
    flow = _load_yaml("kestra/flows-notification/notify_execution_result.yaml")
    trigger = flow["triggers"][0]

    assert trigger["type"] == "io.kestra.plugin.core.trigger.Flow"
    # Kestra 2 removed the condition plugins, so the namespace scope has to come
    # from the when expression rather than a conditions block.
    assert "conditions" not in trigger
    assert trigger["states"] == ["SUCCESS", "FAILED", "WARNING"]
    assert "startsWith('playground.notification')" in trigger["when"]
    assert flow["tasks"][0]["type"] == "io.kestra.plugin.email.MailExecution"


def test_affiliate_notifier_uses_the_1x_conditions_block() -> None:
    flow = _load_yaml("batch-groups/affiliate/flows/notify_affiliate_execution_result.yaml")
    trigger = flow["triggers"][0]

    # The affiliate batch group runs the official kestra/kestra 1.x distribution,
    # which scopes flow triggers with conditions and has no when property.
    assert "when" not in trigger
    assert "states" not in trigger
    conditions = {condition["type"]: condition for condition in trigger["conditions"]}
    status = conditions["io.kestra.plugin.core.condition.ExecutionStatus"]
    namespace = conditions["io.kestra.plugin.core.condition.ExecutionNamespace"]

    assert status["in"] == ["SUCCESS", "FAILED", "WARNING"]
    assert namespace["namespace"] == "playground.affiliate"
    # An exact namespace match keeps playground.affiliate.system out of scope.
    assert namespace["prefix"] is False
    assert flow["tasks"][0]["type"] == "io.kestra.plugin.email.MailExecution"


def test_sample_batches_mail_from_errors_and_keep_finally_for_cleanup() -> None:
    samples = (
        "kestra/flows-notification/sample_sales_batch.yaml",
        "batch-groups/affiliate/flows/sample_affiliate_partner_batch.yaml",
    )

    for path in samples:
        flow = _load_yaml(path)

        error_tasks = flow["errors"]
        assert _task_ids(error_tasks) == ["mail_error_details"], path
        assert error_tasks[0]["type"] == "io.kestra.plugin.email.MailSend", path
        assert "tasksWithState('FAILED')" in error_tasks[0]["subject"], path

        # finally runs while the execution is still RUNNING, so it must not try
        # to report a final state.
        finally_tasks = flow["finally"]
        assert _task_ids(finally_tasks) == ["log_cleanup"], path
        assert all("email" not in task["type"] for task in finally_tasks), path


def test_inline_notification_splits_branches_on_the_final_state() -> None:
    flow = _load_yaml("kestra/flows-notification/demo_inline_notification.yaml")
    after_execution = {task["id"]: task for task in flow["afterExecution"]}

    assert after_execution["notify_success"]["runIf"] == "{{ execution.state == 'SUCCESS' }}"
    assert (
        after_execution["notify_failure"]["runIf"]
        == "{{ execution.state == 'FAILED' or execution.state == 'WARNING' }}"
    )


def test_local_compose_provides_a_mock_mailer_and_the_email_plugin() -> None:
    compose = _load_yaml("local/docker/docker-compose.yml")
    services = compose["services"]

    mailpit = services["mailpit"]
    assert mailpit["image"].startswith("axllent/mailpit:")
    assert "1025:1025" in mailpit["ports"]
    assert "8025:8025" in mailpit["ports"]

    kestra_ec = services["kestra-ec"]
    assert kestra_ec["depends_on"]["mailpit"]["condition"] == "service_started"
    assert any(
        volume.endswith(":/app/plugins/plugin-email.jar:ro") for volume in kestra_ec["volumes"]
    )


def test_gke_manifests_ship_the_mock_mailer_and_notification_env() -> None:
    kustomization = _load_yaml("k8s/base/kustomization.yaml")
    assert "mailpit.yaml" in kustomization["resources"]

    documents = list(
        yaml.safe_load_all((ROOT / "k8s/base/mailpit.yaml").read_text(encoding="utf-8"))
    )
    kinds = {document["kind"]: document for document in documents}
    # The sink must stay cluster-internal; it is reached through port-forward.
    assert kinds["Service"]["spec"]["type"] == "ClusterIP"
    assert {port["port"] for port in kinds["Service"]["spec"]["ports"]} == {1025, 8025}

    for path in ("k8s/base/secret.yaml", "k8s/overlays/dev/secret.yaml"):
        secret = _load_yaml(path)
        assert secret["stringData"]["ENV_NOTIFY_SMTP_HOST"] == "mailpit"
        assert secret["stringData"]["ENV_NOTIFY_SMTP_PORT"] == "1025"


def test_env_examples_expose_the_notification_settings_to_flows() -> None:
    for path in (
        "batch-groups/ec/config/envs/local.env.example",
        "batch-groups/affiliate/config/envs/local.env.example",
    ):
        entries = dict(
            line.split("=", maxsplit=1)
            for line in (ROOT / path).read_text(encoding="utf-8").splitlines()
            if line and not line.startswith("#")
        )

        assert entries["ENV_NOTIFY_SMTP_HOST"] == "mailpit"
        assert entries["ENV_NOTIFY_SMTP_PORT"] == "1025"
        assert entries["ENV_NOTIFY_MAIL_TO"] == "ops@playground.local"
