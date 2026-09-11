"""The polling loop: find a file, validate it, run it, route it, report on it.

One process, one pod, one replica, deliberately. The work has no concurrency
requirement - one file-watcher is sufficient - and a second replica without a
claim or locking mechanism would sooner or later process the same file twice.
Running a file twice means running its writes twice, which in production is a
data problem rather than a performance one. Scaling this out would need a
locking mechanism, and a half-built one is worse than none.
"""

from __future__ import annotations

import os
import signal
import sys
import time
import uuid
from datetime import datetime, timezone

from pymongo import MongoClient
from pymongo.errors import PyMongoError

from . import metrics, reporter
from .config import Config, ConfigError, load_config
from .db import Database
from .errors import QuerySyntaxError
from .executor import Executor
from .logger import configure_logging, get_logger, set_run_id
from .models import LineResult, LineStatus, RunResult, RunStatus
from .notifier import Notifier
from .parser import ParsedQuery, is_skippable
from .s3_client import S3Client
from .validator import validate_line

log = get_logger("main")


class Shutdown:
    """Tracks a termination signal without interrupting the file in flight.

    Kubernetes sends SIGTERM and then waits. Abandoning a file part way through
    would leave it in the input bucket with some of its queries already applied
    and no report saying which - so the signal is recorded and acted on at the
    next safe point instead.
    """

    def __init__(self) -> None:
        self.requested = False

    def install(self) -> None:
        signal.signal(signal.SIGTERM, self._handle)
        signal.signal(signal.SIGINT, self._handle)

    def _handle(self, signum: int, _frame) -> None:
        self.requested = True
        log.info(
            "shutdown signal received, will stop after the current file",
            signal=signal.Signals(signum).name,
        )


class Pipeline:
    """One file's journey, and the loop that keeps finding the next one."""

    def __init__(
        self,
        config: Config,
        s3: S3Client,
        executor: Executor,
        database: Database,
        notifier: Notifier,
    ) -> None:
        self._config = config
        self._s3 = s3
        self._executor = executor
        self._db = database
        self._notifier = notifier

    def run_forever(self, shutdown: Shutdown) -> None:
        config = self._config
        log.info(
            "starting the polling loop",
            input_bucket=config.buckets.input,
            poll_interval_seconds=config.poll_interval_seconds,
        )

        while not shutdown.requested:
            try:
                keys = self._s3.list_input_files(config.buckets.input)
                metrics.record_poll(len(keys))

                if keys:
                    log.info("found files awaiting processing", count=len(keys))
                    # One file at a time. The next cycle picks up the rest, and
                    # the input bucket is the queue.
                    self.process_file(keys[0])
                    continue

                log.debug("no files awaiting processing")
            except Exception as error:
                # The loop must outlive any single failure. A bucket that is
                # briefly unreachable should mean a retry in twenty seconds,
                # not a crashlooping pod.
                log.exception("polling cycle failed", error=str(error))

            self._sleep(config.poll_interval_seconds, shutdown)

        log.info("polling loop stopped")

    def _sleep(self, seconds: int, shutdown: Shutdown) -> None:
        """Sleep in one-second steps so a signal is noticed promptly."""
        for _ in range(seconds):
            if shutdown.requested:
                return
            time.sleep(1)

    def process_file(self, key: str) -> RunResult:
        """Process one file end to end."""
        config = self._config
        run_id = str(uuid.uuid4())
        set_run_id(run_id)

        local_path = os.path.join(config.work_dir, f"{run_id}-{os.path.basename(key)}")

        try:
            log.info("starting run", file_name=key)

            file_hash = self._s3.download(config.buckets.input, key, local_path)
            run = RunResult(
                run_id=run_id,
                environment=config.environment,
                file_name=key,
                file_hash=file_hash,
                started_at=datetime.now(timezone.utc),
            )

            self._db.record_run_start(run)

            with open(local_path, "r", encoding="utf-8") as handle:
                raw_lines = handle.readlines()

            log.info("read file", lines=len(raw_lines))

            valid = self._validate_all(run, raw_lines)

            # Execution only starts if every line is well formed. Validating
            # the whole file first is what keeps a typo on line 10 from leaving
            # lines 1 to 9 applied and the file in the failed bucket - which
            # would be the worst of both outcomes, since nothing in the failed
            # bucket looks like it ran.
            if run.failed_lines:
                log.warning(
                    "file failed validation, nothing was executed",
                    fail_syntax=run.syntax_fail_count,
                    not_attempted=len(valid),
                )
                self._record_not_run(run, valid)
            else:
                self._execute_all(run, valid)

            run.complete()
            self._finish(run, key)
            return run

        except Exception as error:
            log.exception("run failed unexpectedly", file_name=key, error=str(error))
            raise
        finally:
            _remove_quietly(local_path)
            set_run_id(None)

    def _validate_all(
        self, run: RunResult, raw_lines: list[str]
    ) -> list[tuple[int, ParsedQuery]]:
        """Check every line. The database is not contacted at all in this pass.

        Returns:
            The lines that passed, already parsed, so the execution pass does
            not parse the file a second time.
        """
        valid: list[tuple[int, ParsedQuery]] = []

        for line_number, raw in enumerate(raw_lines, start=1):
            if is_skippable(raw):
                run.skipped_lines += 1
                log.debug("skipped a blank or comment line", line=line_number)
                continue

            try:
                valid.append((line_number, validate_line(raw)))
                log.debug("line passed validation", line=line_number)
            except QuerySyntaxError as error:
                log.warning(
                    "line failed validation",
                    line=line_number,
                    stage=error.stage,
                    column=error.column,
                    error=error.message,
                )
                run.lines.append(
                    LineResult(
                        line_number=line_number,
                        raw_query=raw.rstrip("\n"),
                        status=LineStatus.FAIL_SYNTAX,
                        error_message=error.message,
                        error_stage=error.stage,
                        error_column=error.column,
                    )
                )

        log.info(
            "validation pass complete",
            checked=len(raw_lines) - run.skipped_lines,
            skipped=run.skipped_lines,
            failed=len(run.lines),
        )
        return valid

    def _record_not_run(
        self, run: RunResult, valid: list[tuple[int, ParsedQuery]]
    ) -> None:
        """Record the valid lines of a file that failed validation.

        They are recorded rather than left out so the report accounts for every
        line in the file. A line simply missing from a report leaves the reader
        to work out whether it ran, which is the one thing the report exists to
        answer.
        """
        for line_number, parsed in valid:
            run.lines.append(
                LineResult(
                    line_number=line_number,
                    raw_query=parsed.raw,
                    status=LineStatus.NOT_RUN,
                )
            )
        run.lines.sort(key=lambda line: line.line_number)

    def _execute_all(self, run: RunResult, valid: list[tuple[int, ParsedQuery]]) -> None:
        """Run every line, continuing past a failure.

        A line that fails at execution does not stop the ones after it. The
        workflow is correct-and-resubmit, and finding every problem in one run
        is what makes that a single round trip instead of several. The report
        records exactly which lines were applied.
        """
        for line_number, parsed in valid:
            run.lines.append(self._executor.execute(parsed, line_number))

        log.info(
            "execution pass complete",
            success=run.success_count,
            fail_execution=run.execution_fail_count,
        )

    def _finish(self, run: RunResult, key: str) -> None:
        """Reports, routing, persistence, notification - in that order.

        Reports are written before the file moves, so a failure while moving
        leaves the evidence in place rather than losing it. The move is what
        takes the file out of the queue, so it happens once everything that
        explains the run is already durable.
        """
        config = self._config
        succeeded = run.status == RunStatus.SUCCESS

        self._s3.upload_text(
            config.buckets.reports_json,
            reporter.report_key(key, run.run_id, "json"),
            reporter.build_json_report(run),
            reporter.JSON_CONTENT_TYPE,
        )
        self._s3.upload_text(
            config.buckets.reports_log,
            reporter.report_key(key, run.run_id, "log"),
            reporter.build_log_report(run),
            reporter.LOG_CONTENT_TYPE,
        )

        # Reports never go to the failed bucket. It stays a clean queue of
        # files that need reprocessing, and nothing else.
        destination = config.buckets.successful if succeeded else config.buckets.failed
        self._s3.move(key, config.buckets.input, destination)

        self._db.record_lines(run)
        self._db.record_run_finish(run)

        if self._notifier.send_run_summary(run):
            self._db.record_notification(
                run,
                "success" if succeeded else "failure",
                self._config.notifier.recipients,
            )

        metrics.record_run(run)

        log.info(
            "run finished",
            status=run.status,
            destination_bucket=destination,
            total_lines=run.total_lines,
            success=run.success_count,
            fail_syntax=run.syntax_fail_count,
            fail_execution=run.execution_fail_count,
            duration_ms=run.duration_ms,
        )


def _remove_quietly(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


def build_pipeline(config: Config) -> tuple[Pipeline, MongoClient, Database]:
    """Wire everything up and prove each dependency is reachable.

    Connectivity is checked at startup rather than on first use. A wrong
    endpoint or a missing permission should be a clear message in the first
    seconds of the pod's life, when someone is watching, not twenty minutes
    later when a file arrives.
    """
    s3 = S3Client(region=config.aws_region, endpoint_url=config.s3_endpoint_url)

    unreachable = s3.check_access(
        [
            config.buckets.input,
            config.buckets.successful,
            config.buckets.failed,
            config.buckets.reports_json,
            config.buckets.reports_log,
        ]
    )
    if unreachable:
        raise RuntimeError(f"these buckets are not reachable: {', '.join(unreachable)}")

    mongo_client = MongoClient(
        config.mongo.uri,
        serverSelectionTimeoutMS=config.mongo.timeout_ms,
    )
    mongo_client.admin.command("ping")
    collection = mongo_client[config.mongo.database][config.mongo.collection]
    log.info(
        "connected to the document database",
        database=config.mongo.database,
        collection=config.mongo.collection,
    )

    database = Database(config.mysql)
    database.connect()
    # Not fatal. Run history is valuable, but a file left stranded in the input
    # bucket because history could not be written would be worse.
    if not database.check_connection():
        log.error("continuing without run history - outcomes will still be in reports and logs")

    notifier = Notifier(config.notifier, region=config.aws_region)

    pipeline = Pipeline(
        config=config,
        s3=s3,
        executor=Executor(collection),
        database=database,
        notifier=notifier,
    )
    return pipeline, mongo_client, database


def main() -> int:
    try:
        config = load_config()
    except ConfigError as error:
        # Logging is not configured yet, and this has to be readable regardless.
        print(f"FATAL: {error}", file=sys.stderr)
        return 2

    configure_logging(
        environment=config.environment,
        level=config.log_level,
        log_dir=config.log_dir,
        log_file=config.log_file,
    )

    log.info(
        "mongo-dcu-pipeline starting",
        env=config.environment,
        region=config.aws_region,
        poll_interval_seconds=config.poll_interval_seconds,
        input_bucket=config.buckets.input,
        mongo_database=config.mongo.database,
        run_history=config.mysql.enabled,
        email=config.notifier.enabled,
    )

    if config.metrics_enabled:
        metrics.start_metrics_server(config.metrics_port)

    mongo_client = None
    database = None

    try:
        pipeline, mongo_client, database = build_pipeline(config)
    except (PyMongoError, RuntimeError) as error:
        log.exception("startup failed", error=str(error))
        return 1

    shutdown = Shutdown()
    shutdown.install()

    try:
        pipeline.run_forever(shutdown)
    finally:
        if database is not None:
            database.close()
        if mongo_client is not None:
            mongo_client.close()
        log.info("mongo-dcu-pipeline stopped")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
