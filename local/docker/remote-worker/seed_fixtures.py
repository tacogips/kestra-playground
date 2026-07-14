"""Create deterministic inputs for the local SSH batch worker image."""

from __future__ import annotations

import json
import sqlite3
import sys
from collections.abc import Sequence
from pathlib import Path

DEFAULT_INPUT_ROOT = Path("/opt/batch-inputs")


def seed_database(input_root: Path) -> None:
    """Create a small ecommerce SQLite database used by the export example."""
    database_path = input_root / "ecommerce.db"
    database_path.unlink(missing_ok=True)
    with sqlite3.connect(database_path) as connection:
        connection.execute(
            """
            CREATE TABLE orders (
                order_id INTEGER PRIMARY KEY,
                business_date TEXT NOT NULL,
                customer_id INTEGER NOT NULL,
                status TEXT NOT NULL,
                net_amount INTEGER NOT NULL
            )
            """
        )
        connection.executemany(
            "INSERT INTO orders VALUES (?, ?, ?, ?, ?)",
            [
                (1, "2026-06-25", 101, "completed", 2800),
                (2, "2026-06-25", 102, "completed", 7200),
                (3, "2026-06-25", 103, "cancelled", 0),
                (4, "2026-06-26", 104, "completed", 5400),
            ],
        )


def seed_logs(input_root: Path) -> None:
    """Create JSON Lines application logs with one deliberately malformed line."""
    log_path = input_root / "application.jsonl"
    records = [
        {
            "timestamp": "2026-06-25T00:00:01Z",
            "level": "INFO",
            "service": "api",
            "message": "request accepted",
        },
        {
            "timestamp": "2026-06-25T00:00:02Z",
            "level": "ERROR",
            "service": "worker",
            "message": "temporary downstream failure",
        },
        {
            "timestamp": "2026-06-25T00:00:03Z",
            "level": "WARN",
            "service": "api",
            "message": "retry scheduled",
        },
        {
            "timestamp": "2026-06-26T00:00:01Z",
            "level": "INFO",
            "service": "api",
            "message": "next partition",
        },
    ]
    contents = "\n".join(json.dumps(record, separators=(",", ":")) for record in records)
    log_path.write_text(f"{contents}\nnot-json\n", encoding="utf-8")


def main(argv: Sequence[str] | None = None) -> None:
    """Seed all worker fixtures."""
    arguments = list(sys.argv[1:] if argv is None else argv)
    if len(arguments) > 1:
        raise SystemExit("usage: seed_fixtures.py [output-directory]")

    input_root = Path(arguments[0]) if arguments else DEFAULT_INPUT_ROOT
    input_root.mkdir(parents=True, exist_ok=True)
    seed_database(input_root)
    seed_logs(input_root)


if __name__ == "__main__":
    main()
