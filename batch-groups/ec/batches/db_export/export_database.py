"""Export a SQLite query result to a CSV static file.

The remote batch framework supplies configuration through ``KESTRA_BATCH_CONFIG`` and the
destination through ``KESTRA_BATCH_OUTPUT``. Shared framework helpers come from
``kestra-batch-common``, resolved from the top-level ``batch-common/`` project during local
development and from the private GCP Artifact Registry in staging and production.
"""

from __future__ import annotations

import csv
import json
import sqlite3
import sys
import time
from pathlib import Path

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
)


def _emit_export_result(row_count: int, elapsed_seconds: float, output_path: Path) -> None:
    emit_kestra_result(
        {"row_count": row_count, "output_name": output_path.name},
        [
            counter_metric("exported_rows", row_count),
            timer_metric("export_duration", elapsed_seconds),
        ],
    )


def validate_input(database_path: Path, query: str) -> None:
    """Validate the source and query contract without creating an artifact."""
    if not database_path.is_file():
        raise FileNotFoundError(f"Database does not exist: {database_path}")
    normalized_query = query.lstrip().lower()
    if not normalized_query.startswith(("select", "with")):
        raise ValueError("Only SELECT or WITH queries are allowed")
    emit_progress("input_validated", database=database_path)


def validate_output(output_path: Path) -> None:
    """Validate that the execute phase produced a readable CSV with a header."""
    if not output_path.is_file():
        raise FileNotFoundError(f"CSV output does not exist: {output_path}")
    with output_path.open(encoding="utf-8", newline="") as output_file:
        header = next(csv.reader(output_file), None)
    if not header or any(not column for column in header):
        raise ValueError("CSV output must contain a non-empty header")
    emit_progress("output_validated", output=output_path)


def export_query(database_path: Path, query: str, output_path: Path) -> int:
    """Run one read-only SQLite query and atomically write its rows as CSV."""
    validate_input(database_path, query)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = output_path.with_suffix(f"{output_path.suffix}.tmp")
    database_uri = f"file:{database_path.resolve()}?mode=ro"

    emit_progress("connect", database=database_path)
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
                        emit_progress("export", rows=row_count)
            temporary_path.replace(output_path)
        except BaseException:
            temporary_path.unlink(missing_ok=True)
            raise

    emit_progress("complete", rows=row_count, output=output_path)
    return row_count


def main(arguments: list[str] | None = None) -> int:
    """Run one independently retryable batch phase, or every phase for compatibility."""
    started_at = time.monotonic()
    try:
        selected_arguments = sys.argv[1:] if arguments is None else arguments
        phase = select_phase(selected_arguments)
        config = load_config()
        database_path = Path(required_string(config, "database_path"))
        query = required_string(config, "query")
        artifact_path = output_path()
        if phase in {"all", "validate-input"}:
            validate_input(database_path, query)
        if phase in {"all", "execute"}:
            row_count = export_query(database_path, query, artifact_path)
            _emit_export_result(row_count, time.monotonic() - started_at, artifact_path)
        if phase in {"all", "validate-output"}:
            validate_output(artifact_path)
    except (FileNotFoundError, json.JSONDecodeError, sqlite3.Error, ValueError) as error:
        return report_batch_error(error)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
