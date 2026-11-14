"""Aggregate affiliate conversion events into a static commission summary file.

The remote batch framework supplies configuration through ``KESTRA_BATCH_CONFIG`` and the
destination through ``KESTRA_BATCH_OUTPUT``. Shared framework helpers come from
``kestra-batch-common``, resolved from the top-level ``batch-common/`` project during local
development and from the private GCP Artifact Registry in staging and production.
"""

from __future__ import annotations

import json
import time
from collections import Counter
from pathlib import Path
from typing import TypedDict

from kestra_batch_common import (
    counter_metric,
    emit_kestra_result,
    emit_progress,
    load_config,
    output_path,
    report_batch_error,
    required_string,
    timer_metric,
    write_json_atomically,
)


class ConversionSummary(TypedDict):
    business_date: str
    input_file: str
    total_events: int
    matched_events: int
    malformed_events: int
    conversions_by_status: dict[str, int]
    commission_by_partner: dict[str, float]
    approved_commission_total: float


def _emit_conversion_result(
    matched_events: int, approved_commission_total: float, elapsed_seconds: float
) -> None:
    emit_kestra_result(
        {
            "conversion_events": matched_events,
            "approved_commission_total": approved_commission_total,
        },
        [
            counter_metric("conversion_events", matched_events),
            counter_metric("approved_commission_total", approved_commission_total),
            timer_metric("aggregate_duration", elapsed_seconds),
        ],
    )


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

    emit_progress("open", input=input_path, business_date=business_date)
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
                emit_progress("parse", malformed_event=total_events)
                continue

            if not occurred_at.startswith(business_date):
                continue
            matched_events += 1
            conversions_by_status[status.lower()] += 1
            if status.lower() == "approved":
                commission_by_partner[partner_code] += float(commission)
                approved_commission_total += float(commission)
            if matched_events == 1 or matched_events % 1000 == 0:
                emit_progress("parse", matched=matched_events)

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
    write_json_atomically(output_path, result)
    emit_progress(
        "complete", matched=matched_events, malformed=malformed_events, output=output_path
    )
    return result


def main() -> int:
    """Execute the configured aggregation and translate expected input errors to exit 64."""
    started_at = time.monotonic()
    try:
        config = load_config()
        input_path = Path(required_string(config, "input_path"))
        business_date = required_string(config, "business_date")
        artifact_path = output_path()
        result = aggregate_conversions(input_path, artifact_path, business_date)
    except (FileNotFoundError, json.JSONDecodeError, OSError, ValueError) as error:
        return report_batch_error(error)

    _emit_conversion_result(
        result["matched_events"],
        result["approved_commission_total"],
        time.monotonic() - started_at,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
