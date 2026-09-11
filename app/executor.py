"""Execution of a validated query against MongoDB or DocumentDB.

Only lines that passed all five validation checks reach this module, so it is
concerned with what the database says rather than with whether the query makes
sense.

The driver is pymongo in both cases. DocumentDB speaks the MongoDB wire
protocol, which is why local development against a MongoDB container is a
reasonable stand-in - within the operator subset the validator enforces.
"""

from __future__ import annotations

import time
from typing import Any

from pymongo.collection import Collection
from pymongo.errors import PyMongoError

from .logger import get_logger
from .models import LineResult, LineStatus
from .parser import ParsedQuery

log = get_logger("executor")


class Executor:
    """Runs validated queries against one collection."""

    def __init__(self, collection: Collection) -> None:
        self._collection = collection

    def execute(self, parsed: ParsedQuery, line_number: int) -> LineResult:
        """Run one validated query.

        Args:
            parsed: a query that has already passed validation.
            line_number: 1-based line number in the source file, for reports.

        Returns:
            A LineResult that is either a success carrying what the database
            did, or a fail_execution carrying why it did not.
        """
        started = time.monotonic()

        log.debug(
            "executing line",
            line=line_number,
            operation=parsed.operation,
            collection=parsed.collection,
        )

        try:
            detail = self._dispatch(parsed)
        except PyMongoError as error:
            duration_ms = int((time.monotonic() - started) * 1000)
            message = _driver_message(error)
            log.warning(
                "execution failed",
                line=line_number,
                operation=parsed.operation,
                error=message,
                duration_ms=duration_ms,
            )
            return LineResult(
                line_number=line_number,
                raw_query=parsed.raw,
                status=LineStatus.FAIL_EXECUTION,
                error_message=message,
                duration_ms=duration_ms,
            )

        duration_ms = int((time.monotonic() - started) * 1000)

        # A write that matched nothing is reported as a failure even though the
        # driver raised nothing. This is the quiet defect the pipeline exists
        # to catch: a typo in a field name, or an identifier that does not
        # exist, produces a perfectly valid update that changes nothing at all.
        # Left as a success it would be indistinguishable from work done.
        no_match = _no_match_reason(parsed.operation, detail)
        if no_match:
            log.warning(
                "execution matched no documents",
                line=line_number,
                operation=parsed.operation,
                duration_ms=duration_ms,
                **detail,
            )
            return LineResult(
                line_number=line_number,
                raw_query=parsed.raw,
                status=LineStatus.FAIL_EXECUTION,
                error_message=no_match,
                detail=detail,
                duration_ms=duration_ms,
            )

        log.info(
            "execution succeeded",
            line=line_number,
            operation=parsed.operation,
            duration_ms=duration_ms,
            **detail,
        )
        return LineResult(
            line_number=line_number,
            raw_query=parsed.raw,
            status=LineStatus.SUCCESS,
            detail=detail,
            duration_ms=duration_ms,
        )

    def _dispatch(self, parsed: ParsedQuery) -> dict[str, Any]:
        handler = {
            "find": self._find,
            "insertOne": self._insert_one,
            "insertMany": self._insert_many,
            "updateOne": self._update,
            "updateMany": self._update,
            "deleteOne": self._delete,
            "deleteMany": self._delete,
            "aggregate": self._aggregate,
        }[parsed.operation]
        return handler(parsed)

    def _find(self, parsed: ParsedQuery) -> dict[str, Any]:
        filter_doc = parsed.arguments[0] if parsed.arguments else {}
        projection = parsed.arguments[1] if len(parsed.arguments) > 1 else None

        cursor = self._collection.find(filter_doc, projection)

        sort = parsed.modifier("sort")
        if sort is not None:
            cursor = cursor.sort(list(sort.arguments[0].items()))

        limit = parsed.modifier("limit")
        if limit is not None:
            cursor = cursor.limit(limit.arguments[0])

        # A find that matches nothing is a legitimate answer, not a failure.
        # Unlike a write, it changed nothing and claimed to change nothing.
        return {"result_count": len(list(cursor))}

    def _insert_one(self, parsed: ParsedQuery) -> dict[str, Any]:
        result = self._collection.insert_one(parsed.arguments[0])
        return {"inserted_count": 1, "inserted_id": str(result.inserted_id)}

    def _insert_many(self, parsed: ParsedQuery) -> dict[str, Any]:
        result = self._collection.insert_many(parsed.arguments[0])
        return {"inserted_count": len(result.inserted_ids)}

    def _update(self, parsed: ParsedQuery) -> dict[str, Any]:
        filter_doc, update_doc = parsed.arguments[0], parsed.arguments[1]
        options = parsed.arguments[2] if len(parsed.arguments) > 2 else {}
        upsert = bool(options.get("upsert", False))

        method = (
            self._collection.update_one
            if parsed.operation == "updateOne"
            else self._collection.update_many
        )
        result = method(filter_doc, update_doc, upsert=upsert)

        detail = {
            "matched_count": result.matched_count,
            "modified_count": result.modified_count,
        }
        if result.upserted_id is not None:
            detail["upserted_id"] = str(result.upserted_id)
        return detail

    def _delete(self, parsed: ParsedQuery) -> dict[str, Any]:
        method = (
            self._collection.delete_one
            if parsed.operation == "deleteOne"
            else self._collection.delete_many
        )
        result = method(parsed.arguments[0])
        return {"deleted_count": result.deleted_count}

    def _aggregate(self, parsed: ParsedQuery) -> dict[str, Any]:
        cursor = self._collection.aggregate(parsed.arguments[0])
        return {"result_count": len(list(cursor))}


def _no_match_reason(operation: str, detail: dict[str, Any]) -> str | None:
    """Why a write that raised nothing should still count as a failure."""
    if operation in ("updateOne", "updateMany"):
        if detail.get("matched_count", 0) == 0 and "upserted_id" not in detail:
            return (
                "filter matched no documents, so nothing was updated - "
                "check the field names and values in the filter"
            )
    elif operation in ("deleteOne", "deleteMany"):
        if detail.get("deleted_count", 0) == 0:
            return (
                "filter matched no documents, so nothing was deleted - "
                "check the field names and values in the filter"
            )
    return None


def _driver_message(error: PyMongoError) -> str:
    """One readable line out of a driver exception.

    pymongo messages can run to several lines and repeat the full server
    response. A report row has space for one line.
    """
    text = str(error).strip()
    first_line = text.splitlines()[0] if text else error.__class__.__name__
    return f"{error.__class__.__name__}: {first_line}"
