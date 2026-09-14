"""Tests for one file's journey through the pipeline, with every dependency faked.

S3, MySQL, DocumentDB and SES are replaced by small in-memory stand-ins, so
these run in milliseconds and exercise exactly the decisions Phase 9 added:
qa issuing a promotion token, and prod refusing a file it must not run.
"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import timedelta

import pytest

from app.config import Config, MongoSettings, MySQLSettings, NotifierSettings, S3Buckets
from app.db import RunHistoryUnavailable
from app.main import Pipeline
from app.models import LineResult, LineStatus, RunStatus
from app.notifier import _body, _subject

BUCKETS = S3Buckets(
    input="input",
    successful="successful",
    failed="failed",
    reports_json="reports-json",
    reports_log="reports-log",
)

GOOD_FILE = b"""// two queries and a note
db.properties.find({ "listing_status": "active" })

db.properties.updateOne({ "property_id": "PROP-00042" }, { "$set": { "listing_status": "sold" } })
"""

BAD_FILE = b"""db.properties.find({ "listing_status": "active" })
db.properties.find({ "bedrooms": 4 )
"""


class FakeS3:
    def __init__(self, files: dict[str, bytes]) -> None:
        self.objects: dict[str, dict[str, bytes | str]] = {
            name: {} for name in ("input", "successful", "failed", "reports-json", "reports-log")
        }
        self.objects["input"].update(files)

    def download(self, bucket: str, key: str, destination: str) -> str:
        data = self.objects[bucket][key]
        with open(destination, "wb") as handle:
            handle.write(data)
        return hashlib.sha256(data).hexdigest()

    def upload_text(self, bucket: str, key: str, body: str, content_type: str) -> None:
        self.objects[bucket][key] = body

    def move(self, key: str, source_bucket: str, destination_bucket: str) -> None:
        self.objects[destination_bucket][key] = self.objects[source_bucket].pop(key)

    def report(self, kind: str) -> str:
        (body,) = self.objects[f"reports-{kind}"].values()
        return body


class FakeDatabase:
    def __init__(self, prior_prod_runs=(), authorising_qa_run=None, unavailable=False) -> None:
        self._prior = list(prior_prod_runs)
        self._authorising = authorising_qa_run
        self._unavailable = unavailable
        self.started = []
        self.finished = []
        self.notifications = []

    def prior_prod_runs(self, file_hash):
        if self._unavailable:
            raise RunHistoryUnavailable("connection refused")
        return self._prior

    def authorising_qa_run(self, file_hash):
        if self._unavailable:
            raise RunHistoryUnavailable("connection refused")
        return self._authorising

    def record_run_start(self, run):
        self.started.append(run)

    def record_lines(self, run):
        pass

    def record_run_finish(self, run):
        self.finished.append(run)

    def record_notification(self, run, notification_type, recipients):
        self.notifications.append(notification_type)


class FakeExecutor:
    def __init__(self) -> None:
        self.executed = []

    def execute(self, parsed, line_number):
        self.executed.append(line_number)
        return LineResult(line_number=line_number, raw_query=parsed.raw, status=LineStatus.SUCCESS)


class FakeNotifier:
    def __init__(self) -> None:
        self.sent = []

    def send_run_summary(self, run):
        self.sent.append(run)
        return True


def make_config(environment: str, work_dir) -> Config:
    return Config(
        environment=environment,
        aws_region="us-east-1",
        poll_interval_seconds=20,
        work_dir=str(work_dir),
        log_dir=str(work_dir),
        log_file="app.log",
        log_level="INFO",
        metrics_enabled=False,
        metrics_port=9090,
        promotion_token_ttl_hours=24,
        buckets=BUCKETS,
        mongo=MongoSettings(uri="mongodb://unused", database="d", collection="c", timeout_ms=100),
        mysql=MySQLSettings(True, "h", 3306, "u", "p", "d", 1),
        notifier=NotifierSettings(enabled=True, sender="s@example.com", recipients=("r@example.com",)),
    )


def run_file(environment, tmp_path, data=GOOD_FILE, database=None):
    s3 = FakeS3({"change.txt": data})
    database = database or FakeDatabase()
    executor = FakeExecutor()
    notifier = FakeNotifier()
    pipeline = Pipeline(make_config(environment, tmp_path), s3, executor, database, notifier)
    run = pipeline.process_file("change.txt")
    return run, s3, database, executor, notifier


# ------------------------------------------------------------------------ qa


def test_a_fully_successful_qa_run_issues_a_token(tmp_path):
    run, s3, database, _, notifier = run_file("qa", tmp_path)

    assert run.status == RunStatus.SUCCESS
    assert re.fullmatch(r"[0-9a-f]{16}", run.promotion_token)
    assert run.token_expires_at == run.completed_at + timedelta(hours=24)
    assert "change.txt" in s3.objects["successful"]

    # The token reaches everything that describes the run: the database row,
    # both reports and the email.
    assert database.finished[0].promotion_token == run.promotion_token
    assert json.loads(s3.report("json"))["promotion"]["token"] == run.promotion_token
    assert run.promotion_token in s3.report("log")
    body = _body(notifier.sent[0])
    assert f"scripts/promote.sh --file <path to change.txt> --token {run.promotion_token}" in body


def test_a_failed_qa_run_issues_no_token(tmp_path):
    run, s3, database, executor, _ = run_file("qa", tmp_path, data=BAD_FILE)

    assert run.status == RunStatus.FAILED
    assert run.promotion_token is None
    assert database.finished[0].token_expires_at is None
    assert executor.executed == []
    assert json.loads(s3.report("json"))["promotion"] is None


def test_dev_issues_no_token_even_on_success(tmp_path):
    run, *_ = run_file("dev", tmp_path)
    assert run.status == RunStatus.SUCCESS
    assert run.promotion_token is None


# ---------------------------------------------------------------------- prod


def test_prod_runs_a_promoted_file_and_records_where_it_came_from(tmp_path):
    database = FakeDatabase(authorising_qa_run="qa-run-1")
    run, s3, database, executor, notifier = run_file("prod", tmp_path, database=database)

    assert run.status == RunStatus.SUCCESS
    assert executor.executed == [2, 4]
    assert run.promoted_from_run_id == "qa-run-1"
    assert database.started[0].promoted_from_run_id == "qa-run-1"
    assert run.promotion_token is None, "prod spends tokens, it never issues them"
    assert "change.txt" in s3.objects["successful"]
    assert "from qa run qa-run-1" in _body(notifier.sent[0])


def test_prod_refuses_a_file_that_was_never_promoted(tmp_path):
    run, s3, database, executor, notifier = run_file("prod", tmp_path, database=FakeDatabase())

    assert run.status == RunStatus.REFUSED
    assert executor.executed == []
    assert "change.txt" in s3.objects["failed"]
    assert "no promotion authorises this file" in run.refusal_reason

    # Every query line is accounted for, and the blank and comment lines are
    # skipped exactly as they would be on a run.
    assert [line.status for line in run.lines] == [LineStatus.NOT_RUN, LineStatus.NOT_RUN]
    assert run.skipped_lines == 2

    report = json.loads(s3.report("json"))
    assert report["status"] == "refused"
    assert report["refusal_reason"] == run.refusal_reason
    assert "why prod refused this file" in s3.report("log")
    assert database.notifications == ["refused"]
    assert _subject(notifier.sent[0]).startswith("[mongo-dcu-pipeline] [prod] REFUSED:")


def test_prod_refuses_a_file_it_has_already_run(tmp_path):
    database = FakeDatabase(prior_prod_runs=["prod-run-1"], authorising_qa_run="qa-run-2")
    run, s3, _, executor, _ = run_file("prod", tmp_path, database=database)

    assert run.status == RunStatus.REFUSED
    assert "already run in prod (run prod-run-1)" in run.refusal_reason
    assert executor.executed == []
    assert "change.txt" in s3.objects["failed"]


def test_prod_leaves_the_file_in_input_when_run_history_is_unreachable(tmp_path):
    s3 = FakeS3({"change.txt": GOOD_FILE})
    database = FakeDatabase(unavailable=True)
    executor = FakeExecutor()
    pipeline = Pipeline(make_config("prod", tmp_path), s3, executor, database, FakeNotifier())

    with pytest.raises(RunHistoryUnavailable):
        pipeline.process_file("change.txt")

    assert "change.txt" in s3.objects["input"]
    assert database.started == [], "no run row, so the retry is not blocked by its own attempt"
    assert executor.executed == []
    assert s3.objects["reports-json"] == {}
