"""Per-run email summaries through SES.

Disabled in local development, where the summary is written to the log instead.
The point of the notification is that somebody who is not watching the pipeline
finds out what happened, and locally the person running it is watching it.

A failure email carries the reasons inline. Someone reading it on a phone
should be able to tell whether the problem is a typo in the file or the
database being unreachable, without opening the report object.
"""

from __future__ import annotations

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from .config import NotifierSettings
from .logger import get_logger
from .models import RunStatus, RunResult

log = get_logger("notifier")

MAX_FAILURES_IN_EMAIL = 20


class Notifier:
    def __init__(self, settings: NotifierSettings, region: str) -> None:
        self._settings = settings
        self._client = boto3.client("ses", region_name=region) if settings.enabled else None

    def send_run_summary(self, run: RunResult) -> bool:
        """Send the summary for a finished run.

        Returns:
            True if an email was actually sent, so the caller only records a
            notification that happened.
        """
        subject = _subject(run)
        body = _body(run)

        if not self._settings.enabled:
            log.info(
                "email notifications are disabled, summary follows",
                subject=subject,
                status=run.status,
                file_name=run.file_name,
            )
            for line in body.splitlines():
                if line.strip():
                    log.info("summary", text=line.strip())
            return False

        try:
            self._client.send_email(
                Source=self._settings.sender,
                Destination={"ToAddresses": list(self._settings.recipients)},
                Message={
                    "Subject": {"Data": subject, "Charset": "UTF-8"},
                    "Body": {"Text": {"Data": body, "Charset": "UTF-8"}},
                },
            )
            log.info(
                "sent run summary email",
                recipients=len(self._settings.recipients),
                subject=subject,
            )
            return True
        except (ClientError, BotoCoreError) as error:
            # A failed email must not fail the run. The file has already been
            # routed and the outcome is already recorded.
            log.error("could not send the run summary email", error=str(error))
            return False


def _subject(run: RunResult) -> str:
    outcome = "SUCCESS" if run.status == RunStatus.SUCCESS else "FAILED"
    return f"[mongo-dcu-pipeline] [{run.environment}] {outcome}: {run.file_name}"


def _body(run: RunResult) -> str:
    lines = [
        f"File        : {run.file_name}",
        f"Environment : {run.environment}",
        f"Run id      : {run.run_id}",
        f"File sha256 : {run.file_hash}",
        f"Started     : {run.started_at.isoformat()}",
        f"Duration    : {run.duration_ms} ms",
        f"Status      : {run.status.upper()}",
        "",
        f"Queries     : {run.total_lines}",
        f"  succeeded : {run.success_count}",
        f"  syntax    : {run.syntax_fail_count}",
        f"  execution : {run.execution_fail_count}",
        f"  not run   : {run.not_run_count}",
        "",
    ]

    if run.status == RunStatus.SUCCESS:
        lines.append("Every query succeeded. The file was moved to the successful bucket.")
    else:
        lines.append(
            "The file was NOT applied. It has been moved to the failed bucket in its"
        )
        lines.append("entirety. The failures below need correcting before resubmitting.")
        lines.append("")

        for failure in run.failed_lines[:MAX_FAILURES_IN_EMAIL]:
            lines.append(f"  line {failure.line_number} [{failure.status}]")
            lines.append(f"    {failure.raw_query.strip()}")
            lines.append(f"    {failure.error_message}")
            lines.append("")

        remaining = len(run.failed_lines) - MAX_FAILURES_IN_EMAIL
        if remaining > 0:
            lines.append(f"  ... and {remaining} more. See the full report.")
            lines.append("")

    lines.append(f"Full report : {run.file_name}.{run.run_id}.report.log")
    return "\n".join(lines)
