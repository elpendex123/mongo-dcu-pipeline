"""Per-run reports, in one machine-readable form and one for people.

Both go to their own bucket on every run, success or failure. They are
deliberately kept out of the -failed bucket so that bucket stays a clean queue
of files that need reprocessing and nothing else.

Both are named ``{source file}.{run_id}.report.{json,log}``, so the two halves
of a run correlate across the two buckets by name alone.
"""

from __future__ import annotations

import json
from typing import Any

from .models import LineStatus, RunResult

JSON_CONTENT_TYPE = "application/json"
LOG_CONTENT_TYPE = "text/plain"

_STATUS_LABEL = {
    LineStatus.SUCCESS: "OK  ",
    LineStatus.FAIL_SYNTAX: "SYN!",
    LineStatus.FAIL_EXECUTION: "EXE!",
    LineStatus.NOT_RUN: "--  ",
}


def report_key(file_name: str, run_id: str, extension: str) -> str:
    return f"{file_name}.{run_id}.report.{extension}"


def build_json_report(run: RunResult) -> str:
    """The machine-readable report.

    Everything the database rows hold, plus the per-line detail, so a run can
    be reconstructed from the object alone if the database is unavailable.
    """
    report: dict[str, Any] = {
        "run_id": run.run_id,
        "environment": run.environment,
        "file_name": run.file_name,
        "file_hash": run.file_hash,
        "status": run.status,
        "started_at": run.started_at.isoformat(),
        "completed_at": run.completed_at.isoformat() if run.completed_at else None,
        "duration_ms": run.duration_ms,
        "totals": {
            "total_lines": run.total_lines,
            "skipped_lines": run.skipped_lines,
            "success": run.success_count,
            "fail_syntax": run.syntax_fail_count,
            "fail_execution": run.execution_fail_count,
            "not_run": run.not_run_count,
        },
        "lines": [
            {
                "line_number": line.line_number,
                "status": line.status,
                "query": line.raw_query,
                "duration_ms": line.duration_ms,
                "detail": line.detail or None,
                "error": (
                    {
                        "message": line.error_message,
                        "stage": line.error_stage,
                        "column": line.error_column,
                    }
                    if line.error_message
                    else None
                ),
            }
            for line in run.lines
        ],
    }
    return json.dumps(report, indent=2, sort_keys=False)


def build_log_report(run: RunResult) -> str:
    """The human-readable report.

    Written for the person who has to fix the file. The failures are repeated
    at the end with the offending line quoted and, where the column is known, a
    caret under it - so the fix does not require counting characters.
    """
    lines: list[str] = []
    rule = "=" * 78

    lines.append(rule)
    lines.append(f"  mongo-dcu-pipeline run report")
    lines.append(rule)
    lines.append(f"  file        : {run.file_name}")
    lines.append(f"  run id      : {run.run_id}")
    lines.append(f"  environment : {run.environment}")
    lines.append(f"  file sha256 : {run.file_hash}")
    lines.append(f"  started     : {run.started_at.isoformat()}")
    lines.append(
        f"  completed   : {run.completed_at.isoformat() if run.completed_at else '-'}"
    )
    lines.append(f"  duration    : {run.duration_ms} ms")
    lines.append(f"  status      : {run.status.upper()}")
    lines.append("")
    lines.append(
        f"  {run.total_lines} queries: "
        f"{run.success_count} succeeded, "
        f"{run.syntax_fail_count} failed syntax, "
        f"{run.execution_fail_count} failed execution"
        + (f", {run.not_run_count} not attempted" if run.not_run_count else "")
        + (f", {run.skipped_lines} blank or comment lines skipped" if run.skipped_lines else "")
    )
    lines.append("")
    lines.append("-" * 78)
    lines.append("  per line")
    lines.append("-" * 78)

    for line in run.lines:
        label = _STATUS_LABEL.get(line.status, "????")
        lines.append(f"  {label} line {line.line_number:>4}  {line.raw_query.strip()}")

        if line.detail:
            detail = "  ".join(f"{key}={value}" for key, value in line.detail.items())
            lines.append(f"            {detail}")
        if line.error_message:
            lines.append(f"            -> {line.error_message}")

    if run.failed_lines:
        lines.append("")
        lines.append("-" * 78)
        lines.append("  what to fix")
        lines.append("-" * 78)
        lines.append("")
        lines.append(
            "  This file was not applied. Every line in it is listed above; the"
        )
        lines.append(
            "  ones marked -- were valid but never attempted, because validation"
        )
        lines.append(
            "  runs over the whole file before anything executes. Correct the"
        )
        lines.append("  failures below and submit the file again.")
        lines.append("")

        for line in run.failed_lines:
            reason = (
                "rejected before reaching the database"
                if line.status == LineStatus.FAIL_SYNTAX
                else "the database rejected it or it matched nothing"
            )
            lines.append(f"  line {line.line_number} - {line.status} ({reason})")
            lines.append(f"    {line.raw_query.strip()}")

            if line.error_column:
                # The caret is positioned against the raw line, allowing for
                # the four-space indent above and any leading whitespace the
                # line itself carries.
                leading = len(line.raw_query) - len(line.raw_query.lstrip())
                caret_offset = max(line.error_column - 1 - leading, 0)
                lines.append("    " + " " * caret_offset + "^")

            lines.append(f"    {line.error_message}")
            if line.error_stage:
                lines.append(f"    failed at the '{line.error_stage}' check")
            lines.append("")

    lines.append(rule)
    return "\n".join(lines) + "\n"
