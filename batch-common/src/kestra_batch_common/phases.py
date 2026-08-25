"""The independently retryable batch phase contract."""

from __future__ import annotations

from collections.abc import Sequence
from typing import Final

PHASES: Final = frozenset({"all", "validate-input", "execute", "validate-output"})


def select_phase(arguments: Sequence[str]) -> str:
    """Return the single requested phase, defaulting to ``all`` for compatibility."""
    phase = arguments[0] if arguments else "all"
    if len(arguments) > 1 or phase not in PHASES:
        raise ValueError(
            "Expected at most one phase: validate-input, execute, validate-output, or all"
        )
    return phase
