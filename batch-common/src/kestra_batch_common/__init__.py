"""Shared runtime helpers for kestra-playground batch scripts."""

from kestra_batch_common.config import (
    CONFIG_ENV,
    OUTPUT_ENV,
    load_config,
    output_path,
    required_env,
    required_string,
)
from kestra_batch_common.errors import BATCH_ERROR_EXIT_CODE, report_batch_error
from kestra_batch_common.io import write_json_atomically
from kestra_batch_common.kestra import (
    counter_metric,
    emit_kestra_result,
    emit_progress,
    timer_metric,
)
from kestra_batch_common.phases import PHASES, select_phase

__version__ = "0.1.0"

__all__ = [
    "BATCH_ERROR_EXIT_CODE",
    "CONFIG_ENV",
    "OUTPUT_ENV",
    "PHASES",
    "counter_metric",
    "emit_kestra_result",
    "emit_progress",
    "load_config",
    "output_path",
    "report_batch_error",
    "required_env",
    "required_string",
    "select_phase",
    "timer_metric",
    "write_json_atomically",
]
