from __future__ import annotations

import pytest

from kestra_batch_common import BATCH_ERROR_EXIT_CODE, PHASES, report_batch_error, select_phase


def test_select_phase_defaults_to_all() -> None:
    assert select_phase([]) == "all"


@pytest.mark.parametrize("phase", sorted(PHASES))
def test_select_phase_accepts_known_phases(phase: str) -> None:
    assert select_phase([phase]) == phase


@pytest.mark.parametrize("arguments", [["unknown"], ["execute", "extra"]])
def test_select_phase_rejects_invalid_arguments(arguments: list[str]) -> None:
    with pytest.raises(ValueError, match="at most one phase"):
        select_phase(arguments)


def test_report_batch_error_prints_stderr_line(capsys: pytest.CaptureFixture[str]) -> None:
    exit_code = report_batch_error(FileNotFoundError("missing input"))

    assert exit_code == BATCH_ERROR_EXIT_CODE
    assert capsys.readouterr().err == "batch_error type=FileNotFoundError message=missing input\n"
