"""Tests for the metrics the alert rules depend on.

The rules use increase(), which only sees a rise between two samples. A series
that first appears already above zero hides the events that created it, so
every series an alert reads has to exist before the first file is processed.
"""

from __future__ import annotations

import pytest
from prometheus_client import REGISTRY

import app.metrics  # noqa: F401 - importing is what creates the series


@pytest.mark.parametrize("status", ["success", "failed", "refused"])
def test_every_file_outcome_exists_before_any_run(status):
    assert REGISTRY.get_sample_value("files_processed_total", {"status": status}) is not None


@pytest.mark.parametrize("reason", ["syntax", "execution"])
def test_every_failure_reason_exists_before_any_run(reason):
    assert REGISTRY.get_sample_value("lines_failed_total", {"reason": reason}) is not None


@pytest.mark.parametrize("status", ["success", "fail_syntax", "fail_execution", "not_run"])
def test_every_line_outcome_exists_before_any_run(status):
    assert REGISTRY.get_sample_value("lines_processed_total", {"status": status}) is not None
