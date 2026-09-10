"""Error types shared by the parsing and validation stages.

Both stages raise the same exception type on purpose. Everything they reject is
reported identically by the pipeline - as ``fail_syntax``, with the database
never contacted - so the caller has one thing to catch. The ``stage`` attribute
records which check rejected the line, which is what makes a report useful
rather than merely accurate.
"""

from __future__ import annotations

# The five checks a line passes through, in the order they run.
STAGE_SHAPE = "shape"
STAGE_DELIMITERS = "delimiters"
STAGE_JSON = "json"
STAGE_OPERATION = "operation"
STAGE_ARITY = "arity"

STAGES = (
    STAGE_SHAPE,
    STAGE_DELIMITERS,
    STAGE_JSON,
    STAGE_OPERATION,
    STAGE_ARITY,
)


class QuerySyntaxError(Exception):
    """A query line that must never reach the database.

    Args:
        message: what is wrong, in terms the person who wrote the line can act
            on.
        stage: which of the five checks rejected it. See the STAGE_* constants.
        column: 1-based column in the original line, where one can be
            identified. Reports quote the line and point at this column, so it
            is worth setting whenever the position is genuinely known rather
            than guessed at.
    """

    def __init__(self, message: str, *, stage: str, column: int | None = None) -> None:
        self.message = message
        self.stage = stage
        self.column = column
        super().__init__(str(self))

    def __str__(self) -> str:
        if self.column is not None:
            return f"{self.message} (col {self.column})"
        return self.message
