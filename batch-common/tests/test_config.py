from __future__ import annotations

from pathlib import Path

import pytest

from kestra_batch_common import (
    CONFIG_ENV,
    OUTPUT_ENV,
    load_config,
    output_path,
    required_env,
    required_string,
)


def test_load_config_returns_json_object(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(CONFIG_ENV, '{"business_date": "2026-06-25"}')
    assert load_config() == {"business_date": "2026-06-25"}


def test_load_config_requires_the_variable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(CONFIG_ENV, raising=False)
    with pytest.raises(ValueError, match=CONFIG_ENV):
        load_config()


def test_load_config_rejects_non_object_json(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(CONFIG_ENV, '["not", "an", "object"]')
    with pytest.raises(ValueError, match="JSON object"):
        load_config()


def test_required_string_returns_value() -> None:
    assert required_string({"key": "value"}, "key") == "value"


@pytest.mark.parametrize("config", [{}, {"key": ""}, {"key": 5}])
def test_required_string_rejects_missing_or_invalid(config: dict[str, object]) -> None:
    with pytest.raises(ValueError, match="non-empty string"):
        required_string(config, "key")


def test_required_env_rejects_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("MISSING_BATCH_ENV", raising=False)
    with pytest.raises(ValueError, match="MISSING_BATCH_ENV"):
        required_env("MISSING_BATCH_ENV")


def test_output_path_reads_output_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(OUTPUT_ENV, "/tmp/artifact.csv")
    assert output_path() == Path("/tmp/artifact.csv")
