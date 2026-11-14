"""Parse JSON Lines application logs and write a static summary file."""

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


class ParseSummary(TypedDict):
    business_date: str
    input_file: str
    total_lines: int
    matched_lines: int
    malformed_lines: int
    levels: dict[str, int]
    services: dict[str, int]


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


def _emit_kestra_result(total_lines: int, error_lines: int, elapsed_seconds: float) -> None:
    payload = {
        "outputs": {"total_lines": total_lines, "error_lines": error_lines},
        "metrics": [
            {"name": "parsed_log_lines", "type": "counter", "value": total_lines},
            {"name": "error_log_lines", "type": "counter", "value": error_lines},
            {"name": "parse_duration", "type": "timer", "value": elapsed_seconds},
        ],
    }
    print(f"::{json.dumps(payload, separators=(',', ':'))}::", flush=True)


def parse_log(input_path: Path, output_path: Path, business_date: str) -> ParseSummary:
    """Summarize valid JSON log records for one date, retaining malformed-line counts."""
    if not input_path.is_file():
        raise FileNotFoundError(f"Log file does not exist: {input_path}")

    levels: Counter[str] = Counter()
    services: Counter[str] = Counter()
    total_lines = 0
    matched_lines = 0
    malformed_lines = 0

    print(f"progress phase=open input={input_path} business_date={business_date}", flush=True)
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
                print(f"progress phase=parse malformed_line={total_lines}", flush=True)
                continue

            if not timestamp.startswith(business_date):
                continue
            matched_lines += 1
            levels[level.upper()] += 1
            services[service] += 1
            if matched_lines == 1 or matched_lines % 1000 == 0:
                print(f"progress phase=parse matched={matched_lines}", flush=True)

    result: ParseSummary = {
        "business_date": business_date,
        "input_file": input_path.name,
        "total_lines": total_lines,
        "matched_lines": matched_lines,
        "malformed_lines": malformed_lines,
        "levels": dict(sorted(levels.items())),
        "services": dict(sorted(services.items())),
    }
    _write_json_atomically(output_path, result)
    print(
        f"progress phase=complete matched={matched_lines} malformed={malformed_lines} "
        f"output={output_path}",
        flush=True,
    )
    return result


def main() -> int:
    """Execute the configured parse and translate expected input errors to exit 64."""
    started_at = time.monotonic()
    try:
        config = _load_config()
        input_path = Path(_required_string(config, "input_path"))
        business_date = _required_string(config, "business_date")
        output_path = Path(_required_env(OUTPUT_ENV))
        result = parse_log(input_path, output_path, business_date)
    except (FileNotFoundError, json.JSONDecodeError, OSError, ValueError) as error:
        print(
            f"batch_error type={type(error).__name__} message={error}",
            file=sys.stderr,
            flush=True,
        )
        return 64

    _emit_kestra_result(
        result["matched_lines"],
        result["levels"].get("ERROR", 0),
        time.monotonic() - started_at,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
