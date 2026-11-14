"""Aggregate affiliate conversion events into a static commission summary file.

The remote batch framework supplies configuration through ``KESTRA_BATCH_CONFIG`` and the
destination through ``KESTRA_BATCH_OUTPUT``. The script only uses the Python standard library so
it can run on a minimally provisioned worker.
"""

from __future__ import annotations

import json
import os
import sys
import time
from collections import Counter
from collections.abc import Mapping
from pathlib import Path
from typing import Final, TypedDict

CONFIG_ENV: Final = "KESTRA_BATCH_CONFIG"
OUTPUT_ENV: Final = "KESTRA_BATCH_OUTPUT"


class ConversionSummary(TypedDict):
    business_date: str
    input_file: str
    total_events: int
    matched_events: int
    malformed_events: int
    conversions_by_status: dict[str, int]
    commission_by_partner: dict[str, float]
    approved_commission_total: float


def _load_config() -> dict[str, object]:
    raw = os.environ.get(CONFIG_ENV)
    if not raw:
        raise ValueError(f"{CONFIG_ENV} is required")

    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError(f"{CONFIG_ENV} must contain a JSON object")
    return value


def _required_string(config: dict[str, object], key: str) -> str:
    value = config.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"Configuration field {key!r} must be a non-empty string")
    return value


def _required_env(key: str) -> str:
    value = os.environ.get(key)
    if not value:
        raise ValueError(f"Environment variable {key} is required")
    return value


def _write_json_atomically(output_path: Path, value: Mapping[str, object]) -> None:
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


def _emit_kestra_result(
    matched_events: int, approved_commission_total: float, elapsed_seconds: float
) -> None:
    payload = {
        "outputs": {
            "conversion_events": matched_events,
            "approved_commission_total": approved_commission_total,
        },
        "metrics": [
            {"name": "conversion_events", "type": "counter", "value": matched_events},
            {
                "name": "approved_commission_total",
                "type": "counter",
                "value": approved_commission_total,
            },
            {"name": "aggregate_duration", "type": "timer", "value": elapsed_seconds},
        ],
    }
    print(f"::{json.dumps(payload, separators=(',', ':'))}::", flush=True)


def aggregate_conversions(
    input_path: Path, output_path: Path, business_date: str
) -> ConversionSummary:
    """Summarize valid conversion events for one date, retaining malformed-event counts."""
    if not input_path.is_file():
        raise FileNotFoundError(f"Conversion event file does not exist: {input_path}")

    conversions_by_status: Counter[str] = Counter()
    commission_by_partner: Counter[str] = Counter()
    approved_commission_total = 0.0
    total_events = 0
    matched_events = 0
    malformed_events = 0

    print(f"progress phase=open input={input_path} business_date={business_date}", flush=True)
    with input_path.open(encoding="utf-8") as input_file:
        for total_events, raw_line in enumerate(input_file, start=1):
            try:
                record = json.loads(raw_line)
                occurred_at = record["occurred_at"]
                partner_code = record["partner_code"]
                status = record["status"]
                commission = record["commission"]
                if not all(isinstance(item, str) for item in (occurred_at, partner_code, status)):
                    raise ValueError("required fields must be strings")
                if not isinstance(commission, (int, float)) or isinstance(commission, bool):
                    raise ValueError("commission must be a number")
            except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                malformed_events += 1
                print(f"progress phase=parse malformed_event={total_events}", flush=True)
                continue

            if not occurred_at.startswith(business_date):
                continue
            matched_events += 1
            conversions_by_status[status.lower()] += 1
            if status.lower() == "approved":
                commission_by_partner[partner_code] += float(commission)
                approved_commission_total += float(commission)
            if matched_events == 1 or matched_events % 1000 == 0:
                print(f"progress phase=parse matched={matched_events}", flush=True)

    result: ConversionSummary = {
        "business_date": business_date,
        "input_file": input_path.name,
        "total_events": total_events,
        "matched_events": matched_events,
        "malformed_events": malformed_events,
        "conversions_by_status": dict(sorted(conversions_by_status.items())),
        "commission_by_partner": {
            partner: round(amount, 2) for partner, amount in sorted(commission_by_partner.items())
        },
        "approved_commission_total": round(approved_commission_total, 2),
    }
    _write_json_atomically(output_path, result)
    print(
        f"progress phase=complete matched={matched_events} malformed={malformed_events} "
        f"output={output_path}",
        flush=True,
    )
    return result


def main() -> int:
    """Execute the configured aggregation and translate expected input errors to exit 64."""
    started_at = time.monotonic()
    try:
        config = _load_config()
        input_path = Path(_required_string(config, "input_path"))
        business_date = _required_string(config, "business_date")
        output_path = Path(_required_env(OUTPUT_ENV))
        result = aggregate_conversions(input_path, output_path, business_date)
    except (FileNotFoundError, json.JSONDecodeError, OSError, ValueError) as error:
        print(
            f"batch_error type={type(error).__name__} message={error}",
            file=sys.stderr,
            flush=True,
        )
        return 64

    _emit_kestra_result(
        result["matched_events"],
        result["approved_commission_total"],
        time.monotonic() - started_at,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
