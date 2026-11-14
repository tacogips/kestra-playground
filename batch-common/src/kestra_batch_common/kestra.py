"""Structured stdout lines that Kestra captures as logs, outputs, and metrics."""

from __future__ import annotations

import json
from collections.abc import Mapping, Sequence


def counter_metric(name: str, value: float) -> dict[str, object]:
    """Build one Kestra counter metric entry."""
    return {"name": name, "type": "counter", "value": value}


def timer_metric(name: str, value: float) -> dict[str, object]:
    """Build one Kestra timer metric entry."""
    return {"name": name, "type": "timer", "value": value}


def emit_kestra_result(
    outputs: Mapping[str, object],
    metrics: Sequence[Mapping[str, object]] = (),
) -> None:
    """Emit the ``::{...}::`` line Kestra parses into task outputs and metrics."""
    payload: dict[str, object] = {"outputs": dict(outputs)}
    if metrics:
        payload["metrics"] = [dict(metric) for metric in metrics]
    print(f"::{json.dumps(payload, separators=(',', ':'))}::", flush=True)


def emit_progress(phase: str, **fields: object) -> None:
    """Emit one ``progress phase=...`` line with optional ``key=value`` fields."""
    parts = [f"progress phase={phase}"]
    parts.extend(f"{key}={value}" for key, value in fields.items())
    print(" ".join(parts), flush=True)
