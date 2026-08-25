"""Uniform reporting for expected batch failures."""

from __future__ import annotations

import sys
from typing import Final

BATCH_ERROR_EXIT_CODE: Final = 64


def report_batch_error(error: BaseException) -> int:
    """Print the standard ``batch_error`` line and return the batch error exit code."""
    print(
        f"batch_error type={type(error).__name__} message={error}",
        file=sys.stderr,
        flush=True,
    )
    return BATCH_ERROR_EXIT_CODE
