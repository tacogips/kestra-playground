"""Environment-driven configuration contract shared by every batch script."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Final

CONFIG_ENV: Final = "KESTRA_BATCH_CONFIG"
OUTPUT_ENV: Final = "KESTRA_BATCH_OUTPUT"


def load_config() -> dict[str, object]:
    """Load the JSON business configuration from ``KESTRA_BATCH_CONFIG``."""
    raw = os.environ.get(CONFIG_ENV)
    if not raw:
        raise ValueError(f"{CONFIG_ENV} is required")

    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError(f"{CONFIG_ENV} must contain a JSON object")
    return value


def required_string(config: dict[str, object], key: str) -> str:
    """Return a mandatory non-empty string field from the batch configuration."""
    value = config.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"Configuration field {key!r} must be a non-empty string")
    return value


def required_env(key: str) -> str:
    """Return a mandatory non-empty environment variable."""
    value = os.environ.get(key)
    if not value:
        raise ValueError(f"Environment variable {key} is required")
    return value


def output_path() -> Path:
    """Return the artifact destination taken from ``KESTRA_BATCH_OUTPUT``."""
    return Path(required_env(OUTPUT_ENV))
