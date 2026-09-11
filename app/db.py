"""Run history in MySQL - the local container in development, RDS in QA and
production.

The application never creates its schema. The tables come from sql/schema.sql,
applied by the MySQL container's entrypoint locally and by an Ansible play
against RDS. An application that runs DDL at startup needs permission to alter
its own tables, which is more than it should have.

Persistence failures are logged and swallowed rather than raised. A database
that cannot be reached is a real problem, but it is a smaller problem than a
file left stranded in the input bucket: the run's outcome is also in the report
objects and in the logs, whereas a file that was never routed is invisible.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

import pymysql

from .config import MySQLSettings
from .logger import get_logger
from .models import RunResult

log = get_logger("db")


class Database:
    """Writes run history. Every method is best-effort by design."""

    def __init__(self, settings: MySQLSettings) -> None:
        self._settings = settings
        self._connection: pymysql.connections.Connection | None = None

    @property
    def enabled(self) -> bool:
        return self._settings.enabled

    def connect(self) -> None:
        if not self._settings.enabled:
            log.info("run history is disabled, skipping the database connection")
            return

        self._connection = pymysql.connect(
            host=self._settings.host,
            port=self._settings.port,
            user=self._settings.user,
            password=self._settings.password,
            database=self._settings.database,
            connect_timeout=self._settings.connect_timeout_seconds,
            autocommit=True,
            charset="utf8mb4",
        )
        log.info(
            "connected to the run history database",
            host=self._settings.host,
            port=self._settings.port,
            database=self._settings.database,
        )

    def close(self) -> None:
        if self._connection is not None:
            self._connection.close()
            self._connection = None
            log.info("closed the run history connection")

    def _cursor(self):
        """A live cursor, reconnecting if the connection has gone away.

        MySQL closes idle connections, and this application is idle between
        polling cycles far more than it is busy.
        """
        if self._connection is None:
            raise RuntimeError("database is not connected")
        self._connection.ping(reconnect=True)
        return self._connection.cursor()

    def record_run_start(self, run: RunResult) -> None:
        """Insert the run as 'running' before any query executes.

        Written first so that a process killed mid-file leaves evidence. A row
        still marked running with no completed_at is how an interrupted run is
        recognised afterwards.
        """
        if not self._settings.enabled:
            return

        try:
            with self._cursor() as cursor:
                cursor.execute(
                    """
                    INSERT INTO runs (
                        run_id, environment, file_name, file_hash,
                        status, started_at
                    ) VALUES (%s, %s, %s, %s, %s, %s)
                    """,
                    (
                        run.run_id,
                        run.environment,
                        run.file_name,
                        run.file_hash,
                        "running",
                        _naive_utc(run.started_at),
                    ),
                )
            log.info("recorded run start", file_name=run.file_name)
        except Exception as error:
            log.exception("could not record the run start", error=str(error))

    def record_run_finish(
        self,
        run: RunResult,
        promotion_token: str | None = None,
        token_expires_at: datetime | None = None,
    ) -> None:
        """Update the run with its outcome, and its promotion token if it has one."""
        if not self._settings.enabled:
            return

        try:
            with self._cursor() as cursor:
                cursor.execute(
                    """
                    UPDATE runs
                       SET total_lines          = %s,
                           success_count        = %s,
                           syntax_fail_count    = %s,
                           execution_fail_count = %s,
                           skipped_lines        = %s,
                           status               = %s,
                           completed_at         = %s,
                           duration_ms          = %s,
                           promotion_token      = %s,
                           token_expires_at     = %s
                     WHERE run_id = %s
                    """,
                    (
                        run.total_lines,
                        run.success_count,
                        run.syntax_fail_count,
                        run.execution_fail_count,
                        run.skipped_lines,
                        run.status,
                        _naive_utc(run.completed_at),
                        run.duration_ms,
                        promotion_token,
                        _naive_utc(token_expires_at),
                        run.run_id,
                    ),
                )
            log.info(
                "recorded run outcome",
                status=run.status,
                total_lines=run.total_lines,
                success=run.success_count,
                fail_syntax=run.syntax_fail_count,
                fail_execution=run.execution_fail_count,
            )
        except Exception as error:
            log.exception("could not record the run outcome", error=str(error))

    def record_lines(self, run: RunResult) -> None:
        """Insert every line's result in one statement."""
        if not self._settings.enabled or not run.lines:
            return

        rows = [
            (
                str(uuid.uuid4()),
                run.run_id,
                run.environment,
                line.line_number,
                line.raw_query,
                line.status,
                line.error_message,
                line.error_stage,
                line.error_column,
                line.duration_ms,
            )
            for line in run.lines
        ]

        try:
            with self._cursor() as cursor:
                cursor.executemany(
                    """
                    INSERT INTO run_lines (
                        line_id, run_id, environment, line_number, raw_query,
                        status, error_message, error_stage, error_column, duration_ms
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    rows,
                )
            log.info("recorded line results", rows=len(rows))
        except Exception as error:
            log.exception("could not record the line results", error=str(error))

    def record_notification(
        self, run: RunResult, notification_type: str, recipients: tuple[str, ...]
    ) -> None:
        if not self._settings.enabled:
            return

        try:
            with self._cursor() as cursor:
                cursor.execute(
                    """
                    INSERT INTO email_notifications (
                        notification_id, run_id, environment, type, recipients, sent_at
                    ) VALUES (%s, %s, %s, %s, %s, %s)
                    """,
                    (
                        str(uuid.uuid4()),
                        run.run_id,
                        run.environment,
                        notification_type,
                        ",".join(recipients) or None,
                        _naive_utc(datetime.now(timezone.utc)),
                    ),
                )
            log.info("recorded notification", type=notification_type)
        except Exception as error:
            log.exception("could not record the notification", error=str(error))

    def check_connection(self) -> bool:
        """Startup smoke test, so a bad password fails at boot with a clear message."""
        if not self._settings.enabled:
            return True
        try:
            with self._cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()
            return True
        except Exception as error:
            log.error("run history database is not reachable", error=str(error))
            return False


def _naive_utc(value: datetime | None) -> datetime | None:
    """Drop the timezone after converting to UTC.

    MySQL DATETIME has no timezone. Everything here is UTC by convention, so
    the offset is stripped on the way in rather than stored inconsistently.
    """
    if value is None:
        return None
    return value.astimezone(timezone.utc).replace(tzinfo=None)
