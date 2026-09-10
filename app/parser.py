"""Parsing of a single mongosh-syntax query line.

Input lines look exactly like what a person would type at a ``mongosh`` prompt::

    db.properties.find({ "listing_status": "active" })
    db.properties.find({ "state": "VA" }).sort({ "listing_price": -1 }).limit(10)
    db.properties.updateOne({ "property_id": "PROP-00042" }, { "$set": { "listing_status": "sold" } })

This module covers the first three of the five checks a line must pass:

1. shape       - it is a ``db.<collection>.<operation>(`` call at all
2. delimiters  - every brace, bracket and parenthesis is balanced
3. json        - the arguments parse, with mongosh's constructors and its
                 looser-than-JSON object syntax both accounted for

Whether the operation is one this pipeline permits, and whether its arguments
make sense for it, is validator.py's job.

Nothing here touches the network or the filesystem. That is deliberate: the
part of the system most likely to need a new rule is also the part that is
cheapest to test, and keeping it free of I/O is what makes it so.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

import json5
from bson import json_util

from .errors import STAGE_DELIMITERS, STAGE_JSON, STAGE_SHAPE, QuerySyntaxError

# db.<collection>.<operation>(
#
# Collection names allow dots so that a namespaced collection still parses and
# is rejected later with a clear message, rather than failing here as a
# malformed line.
_CALL_RE = re.compile(
    r"^db\.(?P<collection>[A-Za-z_][A-Za-z0-9_.\-]*)\.(?P<operation>[A-Za-z][A-Za-z0-9_]*)\s*\("
)

# .limit(10) / .sort({...}) chained onto the end of a call. No ^ anchor: this
# is matched at a position part-way through the line, and ^ would only ever
# match at index 0.
_CHAIN_RE = re.compile(r"\.(?P<name>[A-Za-z][A-Za-z0-9_]*)\s*\(")

_OPENERS = {"{": "}", "[": "]", "(": ")"}
_CLOSERS = {close: open_ for open_, close in _OPENERS.items()}
_QUOTES = ("'", '"')

# mongosh constructors and the extended-JSON form each one maps to. Rewriting
# them up front means the rest of the pipeline only ever deals with JSON, and
# bson.json_util turns these forms into real BSON types on the way out.
_CONSTRUCTORS = {
    "ObjectId": "$oid",
    "ISODate": "$date",
    "Date": "$date",
    "NumberDecimal": "$numberDecimal",
    "NumberLong": "$numberLong",
    "NumberInt": "$numberInt",
}

_CONSTRUCTOR_RE = re.compile(
    r"(?:new\s+)?(" + "|".join(_CONSTRUCTORS) + r")\s*\("
)

_COMMENT_PREFIXES = ("//", "#")


@dataclass(frozen=True)
class Modifier:
    """A chained call such as ``.limit(10)`` or ``.sort({"price": -1})``."""

    name: str
    arguments: tuple[Any, ...]


@dataclass(frozen=True)
class ParsedQuery:
    """One query line, broken into the pieces the executor needs.

    Attributes:
        raw: the line as it appeared in the file, for reports.
        collection: collection name from the ``db.<collection>`` prefix.
        operation: the operation name, not yet checked against the allowlist.
        arguments: positional arguments, already converted to BSON types.
        modifiers: chained calls, in the order they were written.
    """

    raw: str
    collection: str
    operation: str
    arguments: tuple[Any, ...]
    modifiers: tuple[Modifier, ...] = ()

    def modifier(self, name: str) -> Modifier | None:
        """The named modifier, or None if the line did not use it."""
        for mod in self.modifiers:
            if mod.name == name:
                return mod
        return None


def is_skippable(line: str) -> bool:
    """Whether a line is a blank or a comment.

    Skipped rather than failed. A comment in a query file is a note from
    whoever wrote it, and failing the whole file over one would make people
    strip the notes out - which is the opposite of what is wanted.
    """
    stripped = line.strip()
    return not stripped or stripped.startswith(_COMMENT_PREFIXES)


def parse_line(line: str) -> ParsedQuery:
    """Parse one query line.

    Args:
        line: a single line from an input file, with or without its newline.

    Returns:
        The parsed query, arguments already converted to BSON types.

    Raises:
        QuerySyntaxError: at whichever of the first three stages rejected it.
    """
    raw = line.rstrip("\n").rstrip("\r")

    # Columns are reported against the original line, so the offset lost to
    # leading whitespace has to be carried through every message.
    offset = len(raw) - len(raw.lstrip())
    text = raw.strip()

    if not text:
        raise QuerySyntaxError("line is empty", stage=STAGE_SHAPE)

    # A trailing semicolon is habit from the shell, not an error.
    if text.endswith(";"):
        text = text[:-1].rstrip()

    match = _CALL_RE.match(text)
    if not match:
        raise QuerySyntaxError(
            "line is not a db.<collection>.<operation>(...) call",
            stage=STAGE_SHAPE,
            column=offset + 1,
        )

    collection = match.group("collection")
    operation = match.group("operation")

    open_index = match.end() - 1
    close_index = _scan_balanced(text, open_index, offset)
    arguments = _parse_arguments(text, open_index + 1, close_index, offset)

    modifiers, end_index = _parse_modifiers(text, close_index + 1, offset)

    trailing = text[end_index:].strip()
    if trailing:
        raise QuerySyntaxError(
            f"unexpected trailing text after the query: {trailing!r}",
            stage=STAGE_SHAPE,
            column=offset + end_index + 1,
        )

    return ParsedQuery(
        raw=raw,
        collection=collection,
        operation=operation,
        arguments=arguments,
        modifiers=modifiers,
    )


def _scan_balanced(text: str, start: int, offset: int) -> int:
    """Find the closer matching the opener at ``start``.

    Runs before any JSON parsing, and that ordering is the whole point. A JSON
    parser handed a line with a missing brace reports that input ended
    unexpectedly, which says nothing about where the mistake is. This walk
    knows which delimiter was left open and where it was opened, so the report
    can say ``unbalanced '{' opened at col 24`` and the person can go straight
    to it.

    Quotes are tracked so that a brace inside a string value is treated as text
    rather than as structure.

    Args:
        text: the statement being scanned.
        start: index of an opening delimiter in ``text``.
        offset: how far ``text`` sits into the original line, for columns.

    Returns:
        Index of the matching closing delimiter.

    Raises:
        QuerySyntaxError: on a mismatched, unexpected or unclosed delimiter.
    """
    stack: list[tuple[str, int]] = []
    quote: str | None = None
    quote_start = -1
    escaped = False

    for index in range(start, len(text)):
        char = text[index]

        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue

        if char in _QUOTES:
            quote = char
            quote_start = index
        elif char in _OPENERS:
            stack.append((char, index))
        elif char in _CLOSERS:
            if not stack:
                raise QuerySyntaxError(
                    f"unexpected '{char}' - nothing was open here",
                    stage=STAGE_DELIMITERS,
                    column=offset + index + 1,
                )
            opener, opener_index = stack.pop()
            if _OPENERS[opener] != char:
                raise QuerySyntaxError(
                    f"'{opener}' opened at col {offset + opener_index + 1} "
                    f"is closed by '{char}'",
                    stage=STAGE_DELIMITERS,
                    column=offset + index + 1,
                )
            if not stack:
                return index

    if quote is not None:
        raise QuerySyntaxError(
            f"unterminated {quote} string",
            stage=STAGE_DELIMITERS,
            column=offset + quote_start + 1,
        )

    # The innermost unclosed delimiter, not the outermost. On the common
    # mistake - a missing closing brace inside a call - the outermost opener is
    # the call's own parenthesis, which is not where the problem is. The
    # innermost one points at the object the writer forgot to close.
    opener, opener_index = stack[-1]
    raise QuerySyntaxError(
        f"unbalanced '{opener}' opened at col {offset + opener_index + 1}",
        stage=STAGE_DELIMITERS,
        column=offset + opener_index + 1,
    )


def _split_top_level(text: str, start: int, end: int) -> list[tuple[int, str]]:
    """Split an argument list on commas that are not inside a nested value.

    Returns:
        (index in ``text`` where the argument begins, the argument text).
    """
    parts: list[tuple[int, str]] = []
    depth = 0
    quote: str | None = None
    escaped = False
    part_start = start

    for index in range(start, end):
        char = text[index]

        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue

        if char in _QUOTES:
            quote = char
        elif char in _OPENERS:
            depth += 1
        elif char in _CLOSERS:
            depth -= 1
        elif char == "," and depth == 0:
            parts.append((part_start, text[part_start:index]))
            part_start = index + 1

    parts.append((part_start, text[part_start:end]))
    return parts


def _parse_arguments(text: str, start: int, end: int, offset: int) -> tuple[Any, ...]:
    """Parse the contents of an argument list into BSON values."""
    if not text[start:end].strip():
        return ()

    values: list[Any] = []
    for part_start, part in _split_top_level(text, start, end):
        if not part.strip():
            raise QuerySyntaxError(
                "empty argument - check for a stray comma",
                stage=STAGE_JSON,
                column=offset + part_start + 1,
            )
        values.append(_parse_value(part, offset + part_start))
    return tuple(values)


def _parse_modifiers(text: str, start: int, offset: int) -> tuple[tuple[Modifier, ...], int]:
    """Parse any chained calls following the main call.

    Returns:
        The modifiers, and the index just past the last one consumed.
    """
    modifiers: list[Modifier] = []
    index = start

    while True:
        while index < len(text) and text[index].isspace():
            index += 1

        if index >= len(text) or text[index] != ".":
            return tuple(modifiers), index

        match = _CHAIN_RE.match(text, index)
        if not match:
            raise QuerySyntaxError(
                "expected a chained call such as .limit(10) or .sort({...})",
                stage=STAGE_SHAPE,
                column=offset + index + 1,
            )

        open_index = match.end() - 1
        close_index = _scan_balanced(text, open_index, offset)
        arguments = _parse_arguments(text, open_index + 1, close_index, offset)

        modifiers.append(Modifier(name=match.group("name"), arguments=arguments))
        index = close_index + 1


def _parse_value(text: str, column_base: int) -> Any:
    """Turn one argument's source text into a BSON value.

    Three passes, each covering something the next one cannot:

    1. mongosh constructors become their extended-JSON equivalents, because
       ``ObjectId("...")`` is a function call and no JSON parser will take it.
    2. json5 handles what people actually type - unquoted keys, single quotes,
       a trailing comma - which strict JSON rejects and which are not real
       mistakes.
    3. bson.json_util turns the extended-JSON forms into genuine ObjectId,
       datetime and Decimal128 instances, so the executor hands pymongo the
       types it expects rather than dictionaries that merely look right.
    """
    rewritten = _rewrite_constructors(text)

    try:
        plain = json5.loads(rewritten)
    except Exception as exc:  # json5 raises several unrelated types
        raise QuerySyntaxError(
            f"argument is not valid JSON: {_first_line(exc)}",
            stage=STAGE_JSON,
            column=column_base + 1,
        ) from exc

    try:
        return json_util.loads(json.dumps(plain))
    except Exception as exc:
        raise QuerySyntaxError(
            f"argument has a bad BSON value: {_first_line(exc)}",
            stage=STAGE_JSON,
            column=column_base + 1,
        ) from exc


def _rewrite_constructors(text: str) -> str:
    """Rewrite mongosh constructors to extended JSON, outside string literals.

    Walking the text rather than running a regex over the whole string means an
    ``ObjectId(...)`` appearing inside a quoted value stays a string, which is
    what it is.
    """
    out: list[str] = []
    index = 0
    quote: str | None = None
    escaped = False

    while index < len(text):
        char = text[index]

        if quote is not None:
            out.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            index += 1
            continue

        if char in _QUOTES:
            quote = char
            out.append(char)
            index += 1
            continue

        match = _CONSTRUCTOR_RE.match(text, index)
        # Guard against matching the tail of a longer identifier, so a field
        # called somethingDate is left alone.
        preceded_by_word = index > 0 and (text[index - 1].isalnum() or text[index - 1] == "_")

        if match and not preceded_by_word:
            open_index = match.end() - 1
            close_index = _scan_balanced(text, open_index, 0)
            inner = text[open_index + 1 : close_index].strip()

            if len(inner) >= 2 and inner[0] == inner[-1] and inner[0] in _QUOTES:
                inner = inner[1:-1]

            out.append(json.dumps({_CONSTRUCTORS[match.group(1)]: inner}))
            index = close_index + 1
            continue

        out.append(char)
        index += 1

    return "".join(out)


def _first_line(exc: Exception) -> str:
    """The first line of an exception message.

    Underlying parsers like to print the offending input and a caret across
    several lines. One line is what fits in a report row.
    """
    return str(exc).strip().splitlines()[0] if str(exc).strip() else exc.__class__.__name__
