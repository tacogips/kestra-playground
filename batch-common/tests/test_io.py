from __future__ import annotations

import json
from pathlib import Path
from unittest import mock

import pytest

from kestra_batch_common import write_json_atomically


def test_write_json_atomically_creates_parent_and_writes_sorted_json(tmp_path: Path) -> None:
    output_path = tmp_path / "nested" / "summary.json"

    write_json_atomically(output_path, {"b": 2, "a": 1})

    assert json.loads(output_path.read_text(encoding="utf-8")) == {"a": 1, "b": 2}
    assert not output_path.with_suffix(".json.tmp").exists()


def test_write_json_atomically_removes_temporary_file_on_failure(tmp_path: Path) -> None:
    output_path = tmp_path / "summary.json"

    with (
        mock.patch.object(Path, "replace", side_effect=OSError("rename failed")),
        pytest.raises(OSError, match="rename failed"),
    ):
        write_json_atomically(output_path, {"a": 1})

    assert not output_path.exists()
    assert not output_path.with_suffix(".json.tmp").exists()
