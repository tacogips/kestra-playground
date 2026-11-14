"""Export a SQLite query result to a CSV static file.

The remote batch framework supplies configuration through ``KESTRA_BATCH_CONFIG`` and the
destination through ``KESTRA_BATCH_OUTPUT``. The script only uses the Python standard library so
it can run on a minimally provisioned worker.
"""

from __future__ import annotations

import csv
import json
import os
import sqlite3
import sys
import time
from pathlib import Path
from typing import Final

CONFIG_ENV: Final = "KESTRA_BATCH_CONFIG"
OUTPUT_ENV: Final = "KESTRA_BATCH_OUTPUT"
PHASES: Final = frozenset({"all", "validate-input", "execute", "validate-output"})


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


def _emit_kestra_result(row_count: int, elapsed_seconds: float, output_path: Path) -> None:
    payload = {
        "outputs": {
            "row_count": row_count,
            "output_name": output_path.name,
        },
        "metrics": [
            {"name": "exported_rows", "type": "counter", "value": row_count},
            {"name": "export_duration", "type": "timer", "value": elapsed_seconds},
        ],
    }
    print(f"::{json.dumps(payload, separators=(',', ':'))}::", flush=True)


def validate_input(database_path: Path, query: str) -> None:
    """Validate the source and query contract without creating an artifact."""
    if not database_path.is_file():
        raise FileNotFoundError(f"Database does not exist: {database_path}")
    normalized_query = query.lstrip().lower()
    if not normalized_query.startswith(("select", "with")):
        raise ValueError("Only SELECT or WITH queries are allowed")
    print(f"progress phase=input_validated database={database_path}", flush=True)


def validate_output(output_path: Path) -> None:
    """Validate that the execute phase produced a readable CSV with a header."""
    if not output_path.is_file():
        raise FileNotFoundError(f"CSV output does not exist: {output_path}")
    with output_path.open(encoding="utf-8", newline="") as output_file:
        header = next(csv.reader(output_file), None)
    if not header or any(not column for column in header):
        raise ValueError("CSV output must contain a non-empty header")
    print(f"progress phase=output_validated output={output_path}", flush=True)


def export_query(database_path: Path, query: str, output_path: Path) -> int:
    """Run one read-only SQLite query and atomically write its rows as CSV."""
    validate_input(database_path, query)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = output_path.with_suffix(f"{output_path.suffix}.tmp")
    database_uri = f"file:{database_path.resolve()}?mode=ro"

    print(f"progress phase=connect database={database_path}", flush=True)
    with sqlite3.connect(database_uri, uri=True) as connection:
        connection.row_factory = sqlite3.Row
        cursor = connection.execute(query)
        if cursor.description is None:
            raise ValueError("The query did not return a result set")

        columns = [column[0] for column in cursor.description]
        row_count = 0
        try:
            with temporary_path.open("w", encoding="utf-8", newline="") as output_file:
                writer = csv.writer(output_file)
                writer.writerow(columns)
                for row_count, row in enumerate(cursor, start=1):
                    writer.writerow(tuple(row))
                    if row_count == 1 or row_count % 1000 == 0:
                        print(f"progress phase=export rows={row_count}", flush=True)
            temporary_path.replace(output_path)
        except BaseException:
            temporary_path.unlink(missing_ok=True)
            raise

    print(f"progress phase=complete rows={row_count} output={output_path}", flush=True)
    return row_count


def main(arguments: list[str] | None = None) -> int:
    """Run one independently retryable batch phase, or every phase for compatibility."""
    started_at = time.monotonic()
    try:
        selected_arguments = sys.argv[1:] if arguments is None else arguments
        phase = selected_arguments[0] if selected_arguments else "all"
        if len(selected_arguments) > 1 or phase not in PHASES:
            raise ValueError(
                "Expected at most one phase: validate-input, execute, validate-output, or all"
            )
        config = _load_config()
        database_path = Path(_required_string(config, "database_path"))
        query = _required_string(config, "query")
        output_path = Path(_required_env(OUTPUT_ENV))
        if phase in {"all", "validate-input"}:
            validate_input(database_path, query)
        if phase in {"all", "execute"}:
            row_count = export_query(database_path, query, output_path)
            _emit_kestra_result(row_count, time.monotonic() - started_at, output_path)
        if phase in {"all", "validate-output"}:
            validate_output(output_path)
    except (FileNotFoundError, json.JSONDecodeError, sqlite3.Error, ValueError) as error:
        print(
            f"batch_error type={type(error).__name__} message={error}",
            file=sys.stderr,
            flush=True,
        )
        return 64

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
