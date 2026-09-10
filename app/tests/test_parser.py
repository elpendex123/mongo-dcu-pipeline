"""Tests for the first three validation stages: shape, delimiters, JSON.

The valid cases are a table rather than one test each, because what matters is
that the whole range of things a person might reasonably type is accepted - and
a table makes it obvious at a glance what that range currently is.

The invalid cases are individual tests. Each one asserts the stage that
rejected the line and something specific about the message, since a report that
merely says "invalid" would leave the reader no better off than before.
"""

from __future__ import annotations

import datetime

import pytest
from bson import Decimal128, ObjectId

from app.errors import STAGE_DELIMITERS, STAGE_JSON, STAGE_SHAPE, QuerySyntaxError
from app.parser import is_skippable, parse_line

VALID_LINES = [
    # (line, expected operation, expected argument count, expected modifier names)
    ('db.properties.find({})', "find", 1, ()),
    ('db.properties.find()', "find", 0, ()),
    ('db.properties.find({ "listing_status": "active" })', "find", 1, ()),
    ('db.properties.find({ "bedrooms": { "$gte": 4 } })', "find", 1, ()),
    ('db.properties.find({ "state": "VA" }, { "property_id": 1, "_id": 0 })', "find", 2, ()),
    ('db.properties.find({}).limit(10)', "find", 1, ("limit",)),
    ('db.properties.find({}).sort({ "listing_price": -1 })', "find", 1, ("sort",)),
    ('db.properties.find({}).sort({ "listing_price": -1 }).limit(5)', "find", 1, ("sort", "limit")),
    ('db.properties.insertOne({ "property_id": "PROP-00101" })', "insertOne", 1, ()),
    ('db.properties.insertMany([{ "a": 1 }, { "b": 2 }])', "insertMany", 1, ()),
    (
        'db.properties.updateOne({ "property_id": "PROP-00042" }, { "$set": { "listing_status": "sold" } })',
        "updateOne",
        2,
        (),
    ),
    ('db.properties.deleteOne({ "property_id": "PROP-00042" })', "deleteOne", 1, ()),
    (
        'db.properties.aggregate([{ "$match": { "state": "VA" } }, { "$group": { "_id": "$city", "n": { "$sum": 1 } } }])',
        "aggregate",
        1,
        (),
    ),
    # A trailing semicolon is habit from the shell, not a mistake.
    ('db.properties.find({ "a": 1 });', "find", 1, ()),
    # Leading and trailing whitespace.
    ('   db.properties.find({ "a": 1 })   ', "find", 1, ()),
    # json5 leniency: unquoted keys, single quotes, trailing comma.
    ("db.properties.find({ listing_status: 'active', })", "find", 1, ()),
    # A brace inside a string value is text, not structure.
    ('db.properties.find({ "current_owner": "Smith } Trust" })', "find", 1, ()),
    # Nested arrays and documents.
    ('db.properties.find({ "$or": [{ "a": 1 }, { "b": { "$in": [1, 2, 3] } }] })', "find", 1, ()),
]


@pytest.mark.parametrize("line,operation,argument_count,modifiers", VALID_LINES)
def test_valid_lines_parse(line, operation, argument_count, modifiers):
    parsed = parse_line(line)

    assert parsed.collection == "properties"
    assert parsed.operation == operation
    assert len(parsed.arguments) == argument_count
    assert tuple(modifier.name for modifier in parsed.modifiers) == modifiers


def test_raw_preserves_the_original_line():
    line = '  db.properties.find({ "a": 1 })  '
    assert parse_line(line).raw == line.rstrip("\n")


@pytest.mark.parametrize(
    "line",
    ["", "   ", "\n", "// a note about the next query", "  # another comment style"],
)
def test_blank_and_comment_lines_are_skippable(line):
    assert is_skippable(line)


@pytest.mark.parametrize("line", ['db.properties.find({})', "  db.a.find()  "])
def test_real_queries_are_not_skippable(line):
    assert not is_skippable(line)


# --- stage 1: shape ------------------------------------------------------


@pytest.mark.parametrize(
    "line",
    [
        "select * from properties",
        "properties.find({})",
        "db.find({})",
        "db..find({})",
        "find({})",
        'db.properties.find{"a": 1}',
    ],
)
def test_non_db_call_fails_shape(line):
    with pytest.raises(QuerySyntaxError) as caught:
        parse_line(line)
    assert caught.value.stage == STAGE_SHAPE


def test_trailing_text_after_the_query_fails_shape():
    with pytest.raises(QuerySyntaxError) as caught:
        parse_line('db.properties.find({}) and then some')
    assert caught.value.stage == STAGE_SHAPE
    assert "trailing text" in caught.value.message


def test_empty_line_fails_shape():
    with pytest.raises(QuerySyntaxError) as caught:
        parse_line("   ")
    assert caught.value.stage == STAGE_SHAPE


# --- stage 2: delimiters -------------------------------------------------


def test_unclosed_brace_names_the_delimiter_and_where_it_opened():
    """The defect this stage exists for.

    Running the delimiter scan before the JSON parse is what makes this
    message possible. A JSON parser would only report that input ended.
    """
    line = 'db.properties.find({ "bedrooms": 4'
    with pytest.raises(QuerySyntaxError) as caught:
        parse_line(line)

    error = caught.value
    assert error.stage == STAGE_DELIMITERS
    assert "unbalanced '{'" in error.message
    # Column 20 is the '{' itself, 1-based.
    assert error.column == 20
    assert line[error.column - 1] == "{"


def test_brace_closed_by_the_wrong_delimiter_names_both():
    line = 'db.properties.updateOne({ "a": 1 }, { "$set": { "b": 2 } )'
    with pytest.raises(QuerySyntaxError) as caught:
        parse_line(line)

    error = caught.value
    assert error.stage == STAGE_DELIMITERS
    assert "is closed by ')'" in error.message
    assert line[error.column - 1] == ")"


def test_unterminated_string_points_at_the_opening_quote():
    line = 'db.properties.find({ "city": "Reston })'
    with pytest.raises(QuerySyntaxError) as caught:
        parse_line(line)

    error = caught.value
    assert error.stage == STAGE_DELIMITERS
    assert "unterminated" in error.message
    assert line[error.column - 1] == '"'


def test_unexpected_closing_delimiter():
    with pytest.raises(QuerySyntaxError) as caught:
        parse_line('db.properties.find(})')
    assert caught.value.stage == STAGE_DELIMITERS


def test_leading_whitespace_does_not_shift_reported_columns():
    indented = '    db.properties.find({ "a": 1'
    with pytest.raises(QuerySyntaxError) as caught:
        parse_line(indented)
    assert indented[caught.value.column - 1] == "{"


# --- stage 3: JSON -------------------------------------------------------


def test_missing_value_fails_json_not_delimiters():
    with pytest.raises(QuerySyntaxError) as caught:
        parse_line('db.properties.find({ "a": })')
    assert caught.value.stage == STAGE_JSON


def test_stray_comma_in_the_argument_list_is_reported_as_an_empty_argument():
    with pytest.raises(QuerySyntaxError) as caught:
        parse_line("db.properties.find({},)")
    assert caught.value.stage == STAGE_JSON
    assert "stray comma" in caught.value.message


def test_bad_object_id_fails_json():
    with pytest.raises(QuerySyntaxError) as caught:
        parse_line('db.properties.find({ "_id": ObjectId("not-an-object-id") })')
    assert caught.value.stage == STAGE_JSON
    assert "ObjectId" in caught.value.message


def test_error_message_is_a_single_line():
    """Reports put one failure on one row, so messages must not wrap."""
    with pytest.raises(QuerySyntaxError) as caught:
        parse_line('db.properties.find({ "a": })')
    assert "\n" not in str(caught.value)


# --- BSON conversion -----------------------------------------------------


def test_object_id_becomes_a_real_object_id():
    parsed = parse_line('db.properties.find({ "_id": ObjectId("64b7f1c2e1b2c3d4e5f60718") })')
    value = parsed.arguments[0]["_id"]
    assert isinstance(value, ObjectId)
    assert str(value) == "64b7f1c2e1b2c3d4e5f60718"


def test_isodate_becomes_a_datetime():
    parsed = parse_line('db.properties.find({ "last_sold_date": ISODate("2026-01-15T00:00:00Z") })')
    value = parsed.arguments[0]["last_sold_date"]
    assert isinstance(value, datetime.datetime)
    assert value.year == 2026 and value.month == 1 and value.day == 15


def test_number_decimal_becomes_a_decimal128():
    parsed = parse_line('db.properties.insertOne({ "listing_price": NumberDecimal("450000.00") })')
    value = parsed.arguments[0]["listing_price"]
    assert isinstance(value, Decimal128)
    assert str(value) == "450000.00"


def test_new_date_constructor_form_is_accepted():
    parsed = parse_line('db.properties.find({ "created_at": new Date("2026-01-15T00:00:00Z") })')
    assert isinstance(parsed.arguments[0]["created_at"], datetime.datetime)


def test_constructor_inside_a_string_value_stays_a_string():
    """The rewrite is quote-aware, so this is data rather than a constructor."""
    parsed = parse_line('db.properties.find({ "note": "created via ObjectId(\\"x\\")" })')
    assert parsed.arguments[0]["note"] == 'created via ObjectId("x")'


def test_field_name_ending_in_a_constructor_name_is_left_alone():
    parsed = parse_line('db.properties.find({ "lastDate": 1 })')
    assert parsed.arguments[0] == {"lastDate": 1}


def test_dollar_prefixed_operators_survive_the_bson_pass():
    """$set and friends must not be mistaken for extended-JSON type markers."""
    parsed = parse_line('db.properties.updateOne({ "a": 1 }, { "$set": { "b": 2 } })')
    assert parsed.arguments[1] == {"$set": {"b": 2}}


# --- modifiers -----------------------------------------------------------


def test_modifier_arguments_are_parsed():
    parsed = parse_line('db.properties.find({}).sort({ "listing_price": -1 }).limit(10)')

    sort = parsed.modifier("sort")
    limit = parsed.modifier("limit")

    assert sort is not None and sort.arguments == ({"listing_price": -1},)
    assert limit is not None and limit.arguments == (10,)


def test_modifier_lookup_returns_none_when_absent():
    assert parse_line("db.properties.find({})").modifier("limit") is None
