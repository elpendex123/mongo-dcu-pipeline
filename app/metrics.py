"""Prometheus metrics, scraped from the pod by kube-prometheus-stack.

These are the application's own view of itself. Cluster-level facts - pod
restarts, memory, node health - come from the Prometheus stack already, and
DocumentDB and RDS internals come from CloudWatch. Duplicating either here
would add nothing.

Metrics are counters and gauges, never the source of truth. Run history lives
in MySQL; these exist to make a trend visible on a dashboard.
"""

from __future__ import annotations

from prometheus_client import Counter, Gauge, Histogram, start_http_server

from .logger import get_logger
from .models import LineStatus, RunResult

log = get_logger("metrics")

FILES_PROCESSED = Counter(
    "files_processed_total",
    "Files processed, by final outcome.",
    ["status"],
)

LINES_FAILED = Counter(
    "lines_failed_total",
    "Query lines that failed, by the reason they failed.",
    ["reason"],
)

LINES_PROCESSED = Counter(
    "lines_processed_total",
    "Query lines processed, by outcome.",
    ["status"],
)

FILE_PROCESSING_DURATION = Histogram(
    "file_processing_duration_seconds",
    "Wall-clock time to process one file, from download to routed.",
    buckets=(0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300),
)

LAST_RUN_TIMESTAMP = Gauge(
    "last_run_timestamp",
    "Unix timestamp of the most recently completed run.",
)

POLL_CYCLES = Counter(
    "poll_cycles_total",
    "Polling cycles completed, whether or not a file was found.",
)

FILES_WAITING = Gauge(
    "files_waiting",
    "Files sitting in the input bucket at the end of the last polling cycle.",
)


def start_metrics_server(port: int) -> None:
    start_http_server(port)
    log.info("metrics endpoint is listening", port=port, path="/metrics")


def record_run(run: RunResult) -> None:
    """Record one finished run."""
    FILES_PROCESSED.labels(status=run.status).inc()
    FILE_PROCESSING_DURATION.observe(run.duration_ms / 1000.0)

    if run.completed_at is not None:
        LAST_RUN_TIMESTAMP.set(run.completed_at.timestamp())

    for line in run.lines:
        LINES_PROCESSED.labels(status=line.status).inc()

    # Labelled by reason rather than counted together: "the failure rate went
    # up" is a far less useful alert than "syntax failures went up", which
    # points at whoever is writing the files rather than at the database.
    if run.syntax_fail_count:
        LINES_FAILED.labels(reason="syntax").inc(run.syntax_fail_count)
    if run.execution_fail_count:
        LINES_FAILED.labels(reason="execution").inc(run.execution_fail_count)


def record_poll(files_waiting: int) -> None:
    POLL_CYCLES.inc()
    FILES_WAITING.set(files_waiting)
