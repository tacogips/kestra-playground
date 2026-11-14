"""Filesystem helpers for batch artifacts."""

from __future__ import annotations

import json
from collections.abc import Mapping
from pathlib import Path


def write_json_atomically(output_path: Path, value: Mapping[str, object]) -> None:
    """Write a JSON document through a sibling temporary file and atomic rename."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = output_path.with_suffix(f"{output_path.suffix}.tmp")
    try:
        temporary_path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary_path.replace(output_path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise
