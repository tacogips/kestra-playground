"""Parse JSON Lines application logs and write a static summary file.

Shared framework helpers come from ``kestra-batch-common``, resolved from the top-level
``batch-common/`` project during local development and from the private GCP Artifact Registry
in staging and production.
"""

from __future__ import annotations

import json
import sys
import time
from collections import Counter
from pathlib import Path
from typing import TypedDict, cast

from kestra_batch_common import (
    counter_metric,
    emit_kestra_result,
    emit_progress,
    load_config,
    output_path,
    report_batch_error,
    required_string,
    select_phase,
    timer_metric,
    write_json_atomically,
)


class ParseSummary(TypedDict):
    business_date: str
    input_file: str
    total_lines: int
    matched_lines: int
    malformed_lines: int
    levels: dict[str, int]
    services: dict[str, int]


def _emit_parse_result(total_lines: int, error_lines: int, elapsed_seconds: float) -> None:
    emit_kestra_result(
        {"total_lines": total_lines, "error_lines": error_lines},
        [
            counter_metric("parsed_log_lines", total_lines),
            counter_metric("error_log_lines", error_lines),
            timer_metric("parse_duration", elapsed_seconds),
        ],
    )


def validate_input(input_path: Path, business_date: str) -> None:
    """Validate the source contract without creating the output artifact."""
    if not input_path.is_file():
        raise FileNotFoundError(f"Log file does not exist: {input_path}")
    if len(business_date) != 10:
        raise ValueError("business_date must use YYYY-MM-DD")
    emit_progress("input_validated", input=input_path, business_date=business_date)


def validate_output(output_path: Path, business_date: str) -> ParseSummary:
    """Validate the persisted summary contract after the execute phase."""
    if not output_path.is_file():
        raise FileNotFoundError(f"Summary file does not exist: {output_path}")
    value = json.loads(output_path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("Summary output must contain a JSON object")
    if value.get("business_date") != business_date:
        raise ValueError("Summary business_date does not match the configured partition")
    for key in ("total_lines", "matched_lines", "malformed_lines"):
        if not isinstance(value.get(key), int):
            raise ValueError(f"Summary field {key!r} must be an integer")
    for key in ("levels", "services"):
        if not isinstance(value.get(key), dict):
            raise ValueError(f"Summary field {key!r} must be an object")
    emit_progress("output_validated", output=output_path)
    return cast(ParseSummary, value)


def parse_log(input_path: Path, output_path: Path, business_date: str) -> ParseSummary:
    """Summarize valid JSON log records for one date, retaining malformed-line counts."""
    validate_input(input_path, business_date)

    levels: Counter[str] = Counter()
    services: Counter[str] = Counter()
    total_lines = 0
    matched_lines = 0
    malformed_lines = 0

    emit_progress("open", input=input_path, business_date=business_date)
    with input_path.open(encoding="utf-8") as input_file:
        for total_lines, raw_line in enumerate(input_file, start=1):
            try:
                record = json.loads(raw_line)
                timestamp = record["timestamp"]
                level = record["level"]
                service = record["service"]
                if not all(isinstance(item, str) for item in (timestamp, level, service)):
                    raise ValueError("required fields must be strings")
            except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                malformed_lines += 1
                emit_progress("parse", malformed_line=total_lines)
                continue

            if not timestamp.startswith(business_date):
                continue
            matched_lines += 1
            levels[level.upper()] += 1
            services[service] += 1
            if matched_lines == 1 or matched_lines % 1000 == 0:
                emit_progress("parse", matched=matched_lines)

    result: ParseSummary = {
        "business_date": business_date,
        "input_file": input_path.name,
        "total_lines": total_lines,
        "matched_lines": matched_lines,
        "malformed_lines": malformed_lines,
        "levels": dict(sorted(levels.items())),
        "services": dict(sorted(services.items())),
    }
    write_json_atomically(output_path, result)
    emit_progress("complete", matched=matched_lines, malformed=malformed_lines, output=output_path)
    return result


def main(arguments: list[str] | None = None) -> int:
    """Run one independently retryable batch phase, or every phase for compatibility."""
    started_at = time.monotonic()
    try:
        selected_arguments = sys.argv[1:] if arguments is None else arguments
        phase = select_phase(selected_arguments)
        config = load_config()
        input_path = Path(required_string(config, "input_path"))
        business_date = required_string(config, "business_date")
        artifact_path = output_path()
        if phase in {"all", "validate-input"}:
            validate_input(input_path, business_date)
        if phase in {"all", "execute"}:
            result = parse_log(input_path, artifact_path, business_date)
            _emit_parse_result(
                result["matched_lines"],
                result["levels"].get("ERROR", 0),
                time.monotonic() - started_at,
            )
        if phase in {"all", "validate-output"}:
            validate_output(artifact_path, business_date)
    except (FileNotFoundError, json.JSONDecodeError, OSError, ValueError) as error:
        return report_batch_error(error)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
