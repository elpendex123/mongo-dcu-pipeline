"""Validation of a parsed query against what this pipeline permits.

Covers the last two of the five checks:

4. operation - is this an operation the pipeline runs at all, and if it is an
   aggregation, is every stage in it one DocumentDB supports?
5. arity     - do the arguments make sense for that operation?

The allowlist is not a security control. It is a compatibility control: the
pipeline validates in QA against DocumentDB and then runs the same file against
production DocumentDB, so anything DocumentDB does not implement should be
refused where the message can name the problem, not left to surface later as a
driver error from inside a production run.

Local development runs against MongoDB, which implements a good deal more than
DocumentDB does. Without this list, a query using a MongoDB-only feature would
pass locally and fail in QA - the exact class of surprise the whole
validate-then-promote design exists to prevent.
"""

from __future__ import annotations

from typing import Any

from .errors import STAGE_ARITY, STAGE_OPERATION, QuerySyntaxError
from .parser import ParsedQuery, parse_line

# operation -> (minimum arguments, maximum arguments)
ALLOWED_OPERATIONS: dict[str, tuple[int, int]] = {
    "find": (0, 2),  # filter, projection
    "insertOne": (1, 1),
    "insertMany": (1, 2),  # documents, options
    "updateOne": (2, 3),  # filter, update, options
    "updateMany": (2, 3),
    "deleteOne": (1, 2),  # filter, options
    "deleteMany": (1, 2),
    "aggregate": (1, 2),  # pipeline, options
}

# Aggregation stages DocumentDB 5.0 supports and this project uses.
ALLOWED_STAGES = frozenset({"$match", "$group", "$sort", "$project", "$limit", "$lookup"})

# Stages worth naming individually. Each one is a thing that works in MongoDB
# and would otherwise be discovered to be missing at the worst possible moment.
REJECTED_STAGES: dict[str, str] = {
    "$graphLookup": "recursive graph lookups are not supported by DocumentDB",
    "$text": "text search is not supported by DocumentDB",
    "$geoNear": "geospatial queries are not supported by DocumentDB",
    "$unionWith": "$unionWith is not supported by DocumentDB",
    "$merge": "$merge writes to another collection and is outside this pipeline's scope",
    "$out": "$out replaces a whole collection and is outside this pipeline's scope",
}

UPDATE_OPERATORS = frozenset(
    {
        "$set",
        "$unset",
        "$inc",
        "$mul",
        "$min",
        "$max",
        "$rename",
        "$currentDate",
        "$push",
        "$pull",
        "$pullAll",
        "$addToSet",
        "$pop",
        "$setOnInsert",
    }
)

# Chained calls, and which operations may carry them.
ALLOWED_MODIFIERS: dict[str, frozenset[str]] = {
    "sort": frozenset({"find"}),
    "limit": frozenset({"find"}),
}


def validate_line(line: str) -> ParsedQuery:
    """Parse and fully validate one line.

    The single entry point the rest of the application uses. A line that
    returns from here is safe to execute; anything else raises.

    Raises:
        QuerySyntaxError: from whichever of the five stages rejected it.
    """
    parsed = parse_line(line)
    validate(parsed)
    return parsed


def validate(parsed: ParsedQuery) -> None:
    """Check a parsed query against the allowlist and its own argument rules."""
    _check_operation(parsed)
    _check_modifiers(parsed)
    _check_arguments(parsed)


def _check_operation(parsed: ParsedQuery) -> None:
    if parsed.operation not in ALLOWED_OPERATIONS:
        permitted = ", ".join(sorted(ALLOWED_OPERATIONS))
        raise QuerySyntaxError(
            f"operation '{parsed.operation}' is not permitted - allowed operations are: {permitted}",
            stage=STAGE_OPERATION,
        )

    minimum, maximum = ALLOWED_OPERATIONS[parsed.operation]
    count = len(parsed.arguments)
    if not minimum <= count <= maximum:
        expected = f"{minimum}" if minimum == maximum else f"{minimum} to {maximum}"
        raise QuerySyntaxError(
            f"{parsed.operation} takes {expected} argument(s), got {count}",
            stage=STAGE_ARITY,
        )


def _check_modifiers(parsed: ParsedQuery) -> None:
    for modifier in parsed.modifiers:
        if modifier.name not in ALLOWED_MODIFIERS:
            permitted = ", ".join(sorted(ALLOWED_MODIFIERS))
            raise QuerySyntaxError(
                f"chained call '.{modifier.name}()' is not permitted - allowed: {permitted}",
                stage=STAGE_OPERATION,
            )

        if parsed.operation not in ALLOWED_MODIFIERS[modifier.name]:
            allowed_on = ", ".join(sorted(ALLOWED_MODIFIERS[modifier.name]))
            raise QuerySyntaxError(
                f".{modifier.name}() may only be chained onto: {allowed_on}",
                stage=STAGE_OPERATION,
            )

        if len(modifier.arguments) != 1:
            raise QuerySyntaxError(
                f".{modifier.name}() takes exactly 1 argument, got {len(modifier.arguments)}",
                stage=STAGE_ARITY,
            )

    limit = parsed.modifier("limit")
    if limit is not None:
        value = limit.arguments[0]
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise QuerySyntaxError(
                f".limit() takes a positive whole number, got {value!r}",
                stage=STAGE_ARITY,
            )

    sort = parsed.modifier("sort")
    if sort is not None:
        _require_document(sort.arguments[0], ".sort()")
        if not sort.arguments[0]:
            raise QuerySyntaxError(".sort() needs at least one field", stage=STAGE_ARITY)
        for field, direction in sort.arguments[0].items():
            if direction not in (1, -1):
                raise QuerySyntaxError(
                    f".sort() direction for '{field}' must be 1 or -1, got {direction!r}",
                    stage=STAGE_ARITY,
                )


def _check_arguments(parsed: ParsedQuery) -> None:
    handler = {
        "find": _check_find,
        "insertOne": _check_insert_one,
        "insertMany": _check_insert_many,
        "updateOne": _check_update,
        "updateMany": _check_update,
        "deleteOne": _check_delete,
        "deleteMany": _check_delete,
        "aggregate": _check_aggregate,
    }[parsed.operation]
    handler(parsed)


def _check_find(parsed: ParsedQuery) -> None:
    if parsed.arguments:
        _require_document(parsed.arguments[0], "find filter")
        _reject_javascript(parsed.arguments[0], "find filter")
    if len(parsed.arguments) == 2:
        _require_document(parsed.arguments[1], "find projection")


def _check_insert_one(parsed: ParsedQuery) -> None:
    document = parsed.arguments[0]
    _require_document(document, "insertOne document")
    if not document:
        raise QuerySyntaxError("insertOne needs a non-empty document", stage=STAGE_ARITY)
    _reject_operator_keys(document, "insertOne document")


def _check_insert_many(parsed: ParsedQuery) -> None:
    documents = parsed.arguments[0]
    if not isinstance(documents, list):
        raise QuerySyntaxError(
            f"insertMany takes an array of documents, got {_type_name(documents)}",
            stage=STAGE_ARITY,
        )
    if not documents:
        raise QuerySyntaxError("insertMany needs at least one document", stage=STAGE_ARITY)
    for position, document in enumerate(documents, start=1):
        _require_document(document, f"insertMany document {position}")
        _reject_operator_keys(document, f"insertMany document {position}")


def _check_update(parsed: ParsedQuery) -> None:
    operation = parsed.operation
    filter_doc, update_doc = parsed.arguments[0], parsed.arguments[1]

    _require_document(filter_doc, f"{operation} filter")
    _reject_javascript(filter_doc, f"{operation} filter")

    # An update expressed as a pipeline is a MongoDB 4.2 feature DocumentDB
    # does not implement.
    if isinstance(update_doc, list):
        raise QuerySyntaxError(
            f"{operation} does not accept an aggregation pipeline as its update - "
            "use update operators such as $set",
            stage=STAGE_ARITY,
        )

    _require_document(update_doc, f"{operation} update")

    if not update_doc:
        raise QuerySyntaxError(f"{operation} needs a non-empty update", stage=STAGE_ARITY)

    # A bare document here would replace the matched document wholesale rather
    # than change the fields named. That is almost never what someone editing
    # a query file means, and it is unrecoverable once run against production.
    plain_keys = [key for key in update_doc if not key.startswith("$")]
    if plain_keys:
        raise QuerySyntaxError(
            f"{operation} update must use update operators such as $set - "
            f"a bare field ({plain_keys[0]!r}) would replace the whole document",
            stage=STAGE_ARITY,
        )

    unknown = sorted(key for key in update_doc if key not in UPDATE_OPERATORS)
    if unknown:
        permitted = ", ".join(sorted(UPDATE_OPERATORS))
        raise QuerySyntaxError(
            f"update operator '{unknown[0]}' is not permitted - allowed: {permitted}",
            stage=STAGE_OPERATION,
        )


def _check_delete(parsed: ParsedQuery) -> None:
    filter_doc = parsed.arguments[0]
    _require_document(filter_doc, f"{parsed.operation} filter")
    _reject_javascript(filter_doc, f"{parsed.operation} filter")

    # deleteMany({}) empties the collection. In production that is a data-loss
    # event dressed up as a query, so it has to be written deliberately rather
    # than arrived at by leaving a filter out.
    if not filter_doc:
        raise QuerySyntaxError(
            f"{parsed.operation} needs a filter - an empty filter would delete "
            "every document in the collection",
            stage=STAGE_ARITY,
        )


def _check_aggregate(parsed: ParsedQuery) -> None:
    pipeline = parsed.arguments[0]

    if not isinstance(pipeline, list):
        raise QuerySyntaxError(
            f"aggregate takes an array of stages, got {_type_name(pipeline)}",
            stage=STAGE_ARITY,
        )
    if not pipeline:
        raise QuerySyntaxError("aggregate needs at least one stage", stage=STAGE_ARITY)

    for position, stage in enumerate(pipeline, start=1):
        _require_document(stage, f"aggregate stage {position}")

        if len(stage) != 1:
            raise QuerySyntaxError(
                f"aggregate stage {position} must have exactly one operator, "
                f"got {len(stage)}",
                stage=STAGE_ARITY,
            )

        name = next(iter(stage))

        if name in REJECTED_STAGES:
            raise QuerySyntaxError(
                f"aggregate stage {position} uses {name}: {REJECTED_STAGES[name]}",
                stage=STAGE_OPERATION,
            )

        if name not in ALLOWED_STAGES:
            permitted = ", ".join(sorted(ALLOWED_STAGES))
            raise QuerySyntaxError(
                f"aggregate stage {position} uses '{name}', which is not permitted - "
                f"allowed stages are: {permitted}",
                stage=STAGE_OPERATION,
            )

        if name == "$lookup":
            _check_lookup(stage[name], position)


def _check_lookup(spec: Any, position: int) -> None:
    """Only the simple equality form of $lookup.

    DocumentDB supports joining on a local and a foreign field. It does not
    support the ``let``/``pipeline`` form, which lets the joined collection be
    filtered by a correlated subquery.
    """
    _require_document(spec, f"aggregate stage {position} $lookup")

    for unsupported in ("pipeline", "let"):
        if unsupported in spec:
            raise QuerySyntaxError(
                f"aggregate stage {position} uses the $lookup '{unsupported}' form, "
                "which is not supported by DocumentDB - use localField and foreignField",
                stage=STAGE_OPERATION,
            )

    required = ("from", "localField", "foreignField", "as")
    missing = [key for key in required if key not in spec]
    if missing:
        raise QuerySyntaxError(
            f"aggregate stage {position} $lookup is missing: {', '.join(missing)}",
            stage=STAGE_ARITY,
        )


def _require_document(value: Any, what: str) -> None:
    if not isinstance(value, dict):
        raise QuerySyntaxError(
            f"{what} must be a document, got {_type_name(value)}",
            stage=STAGE_ARITY,
        )


def _reject_operator_keys(document: dict, what: str) -> None:
    """Insert documents must not contain operator keys.

    ``insertOne({"$set": {...}})`` is a filter or an update that ended up in
    the wrong call, and MongoDB rejects the field name anyway.
    """
    operators = sorted(key for key in document if key.startswith("$"))
    if operators:
        raise QuerySyntaxError(
            f"{what} contains the operator key '{operators[0]}' - "
            "insert documents hold field values, not operators",
            stage=STAGE_ARITY,
        )


def _reject_javascript(filter_doc: dict, what: str) -> None:
    """Refuse $where, which evaluates JavaScript server-side.

    Not supported by DocumentDB, and it would let a query file run arbitrary
    code against the database.
    """
    if "$where" in filter_doc:
        raise QuerySyntaxError(
            f"{what} uses $where, which executes JavaScript and is not supported "
            "by DocumentDB",
            stage=STAGE_OPERATION,
        )


def _type_name(value: Any) -> str:
    return {
        dict: "a document",
        list: "an array",
        str: "a string",
        int: "a number",
        float: "a number",
        bool: "a boolean",
        type(None): "null",
    }.get(type(value), type(value).__name__)
