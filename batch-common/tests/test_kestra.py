from __future__ import annotations

import json

import pytest

from kestra_batch_common import (
    counter_metric,
    emit_kestra_result,
    emit_progress,
    timer_metric,
)


def test_emit_kestra_result_prints_compact_payload(capsys: pytest.CaptureFixture[str]) -> None:
    emit_kestra_result(
        {"row_count": 3},
        [counter_metric("exported_rows", 3), timer_metric("export_duration", 1.5)],
    )

    line = capsys.readouterr().out.strip()
    assert line.startswith("::") and line.endswith("::")
    payload = json.loads(line[2:-2])
    assert payload == {
        "outputs": {"row_count": 3},
        "metrics": [
            {"name": "exported_rows", "type": "counter", "value": 3},
            {"name": "export_duration", "type": "timer", "value": 1.5},
        ],
    }


def test_emit_kestra_result_omits_empty_metrics(capsys: pytest.CaptureFixture[str]) -> None:
    emit_kestra_result({"total": 1})

    payload = json.loads(capsys.readouterr().out.strip()[2:-2])
    assert payload == {"outputs": {"total": 1}}


def test_emit_progress_formats_fields(capsys: pytest.CaptureFixture[str]) -> None:
    emit_progress("export", rows=10, output="/tmp/out.csv")

    assert capsys.readouterr().out == "progress phase=export rows=10 output=/tmp/out.csv\n"
