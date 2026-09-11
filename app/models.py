"""The result types the pipeline passes between its stages.

One run produces one RunResult holding one LineResult per non-skipped line.
The executor fills them in, the reporter renders them, the database persists
them and the notifier summarises them - so the shape is defined once here
rather than re-derived by each.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any


class LineStatus:
    """How a single query line ended.

    The split between the two failures is the point of the whole design.
    fail_syntax is a mistake in the file and the database was never contacted.
    fail_execution means the line was well formed and the data disagreed with
    it - a different problem needing a different fix.
    """

    SUCCESS = "success"
    FAIL_SYNTAX = "fail_syntax"
    FAIL_EXECUTION = "fail_execution"

    # Valid, but never attempted: another line in the file failed validation,
    # so nothing in the file was executed. Recorded rather than omitted, so the
    # report accounts for every line in the file and nobody has to wonder
    # whether a line that is missing from it ran or not.
    NOT_RUN = "not_run"


class RunStatus:
    RUNNING = "running"
    SUCCESS = "success"
    FAILED = "failed"


@dataclass
class LineResult:
    """The outcome of one line."""

    line_number: int
    raw_query: str
    status: str
    error_message: str | None = None
    error_stage: str | None = None
    error_column: int | None = None
    detail: dict[str, Any] = field(default_factory=dict)
    duration_ms: int = 0

    @property
    def failed(self) -> bool:
        return self.status in (LineStatus.FAIL_SYNTAX, LineStatus.FAIL_EXECUTION)


@dataclass
class RunResult:
    """Everything one file's run produced."""

    run_id: str
    environment: str
    file_name: str
    file_hash: str
    started_at: datetime
    completed_at: datetime | None = None
    lines: list[LineResult] = field(default_factory=list)
    skipped_lines: int = 0

    @property
    def total_lines(self) -> int:
        return len(self.lines)

    @property
    def success_count(self) -> int:
        return sum(1 for line in self.lines if line.status == LineStatus.SUCCESS)

    @property
    def syntax_fail_count(self) -> int:
        return sum(1 for line in self.lines if line.status == LineStatus.FAIL_SYNTAX)

    @property
    def execution_fail_count(self) -> int:
        return sum(1 for line in self.lines if line.status == LineStatus.FAIL_EXECUTION)

    @property
    def not_run_count(self) -> int:
        return sum(1 for line in self.lines if line.status == LineStatus.NOT_RUN)

    @property
    def failed_lines(self) -> list[LineResult]:
        return [line for line in self.lines if line.failed]

    @property
    def status(self) -> str:
        """A run succeeds only if every line did.

        One failed line fails the whole file. The file is a unit of work: a
        partially applied set of changes is worse than none, because nobody can
        tell by looking which half ran.
        """
        if self.completed_at is None:
            return RunStatus.RUNNING
        return RunStatus.FAILED if self.failed_lines else RunStatus.SUCCESS

    @property
    def duration_ms(self) -> int:
        if self.completed_at is None:
            return 0
        return int((self.completed_at - self.started_at).total_seconds() * 1000)

    def complete(self) -> None:
        self.completed_at = datetime.now(timezone.utc)
