"""Tests for the last two validation stages: operation allowlist and arity.

Every rejection here is a query that MongoDB would happily run locally. That is
the point of the stage: local development runs against MongoDB and production
runs against DocumentDB, and this is where the difference between them is
caught - with a message naming the reason, rather than as a driver error part
way through a production file.
"""

from __future__ import annotations

import pytest

from app.errors import STAGE_ARITY, STAGE_OPERATION, QuerySyntaxError
from app.validator import validate_line

ACCEPTED = [
    'db.properties.find({})',
    'db.properties.find()',
    'db.properties.find({ "listing_status": "active" }, { "_id": 0 })',
    'db.properties.find({}).sort({ "listing_price": -1 }).limit(25)',
    'db.properties.insertOne({ "property_id": "PROP-00101", "bedrooms": 3 })',
    'db.properties.insertMany([{ "property_id": "PROP-00102" }, { "property_id": "PROP-00103" }])',
    'db.properties.updateOne({ "property_id": "PROP-00042" }, { "$set": { "listing_status": "sold" } })',
    'db.properties.updateMany({ "state": "VA" }, { "$inc": { "tax_assessed_value": 1000 } })',
    'db.properties.updateOne({ "a": 1 }, { "$set": { "b": 2 } }, { "upsert": true })',
    'db.properties.deleteOne({ "property_id": "PROP-00042" })',
    'db.properties.deleteMany({ "listing_status": "off_market" })',
    'db.properties.aggregate([{ "$match": { "state": "VA" } }])',
    'db.properties.aggregate([{ "$match": {} }, { "$group": { "_id": "$city", "n": { "$sum": 1 } } }, { "$sort": { "n": -1 } }, { "$limit": 10 }])',
    'db.properties.aggregate([{ "$lookup": { "from": "owners", "localField": "current_owner", "foreignField": "name", "as": "owner" } }])',
]


@pytest.mark.parametrize("line", ACCEPTED)
def test_accepted_lines(line):
    assert validate_line(line).collection == "properties"


def assert_rejected(line: str, stage: str, fragment: str) -> QuerySyntaxError:
    with pytest.raises(QuerySyntaxError) as caught:
        validate_line(line)
    assert caught.value.stage == stage
    assert fragment in caught.value.message
    return caught.value


# --- stage 4: operation allowlist ----------------------------------------


@pytest.mark.parametrize(
    "line",
    [
        "db.properties.drop()",
        "db.properties.countDocuments({})",
        'db.properties.replaceOne({ "a": 1 }, { "b": 2 })',
        'db.properties.findOneAndUpdate({ "a": 1 }, { "$set": { "b": 2 } })',
        "db.properties.createIndex({ 'city': 1 })",
    ],
)
def test_operations_outside_the_allowlist_are_rejected(line):
    assert_rejected(line, STAGE_OPERATION, "is not permitted")


def test_rejection_message_lists_what_is_allowed():
    """A person who hits this needs to know what to write instead."""
    error = assert_rejected("db.properties.drop()", STAGE_OPERATION, "not permitted")
    for operation in ("find", "insertOne", "updateOne", "deleteOne", "aggregate"):
        assert operation in error.message


@pytest.mark.parametrize(
    "stage_name",
    ["$graphLookup", "$text", "$geoNear", "$unionWith", "$merge", "$out"],
)
def test_named_unsupported_stages_explain_themselves(stage_name):
    line = 'db.properties.aggregate([{ "%s": {} }])' % stage_name
    error = assert_rejected(line, STAGE_OPERATION, stage_name)
    # Not just "not allowed" - the reason it cannot work here.
    assert "DocumentDB" in error.message or "scope" in error.message


def test_unlisted_aggregation_stage_is_rejected_with_the_permitted_set():
    error = assert_rejected(
        'db.properties.aggregate([{ "$unwind": "$rooms" }])',
        STAGE_OPERATION,
        "$unwind",
    )
    assert "$match" in error.message and "$group" in error.message


def test_lookup_pipeline_form_is_rejected():
    assert_rejected(
        'db.properties.aggregate([{ "$lookup": { "from": "owners", "let": {}, "pipeline": [] } }])',
        STAGE_OPERATION,
        "not supported by DocumentDB",
    )


def test_where_javascript_is_rejected():
    assert_rejected(
        'db.properties.find({ "$where": "this.bedrooms > 3" })',
        STAGE_OPERATION,
        "$where",
    )


def test_unknown_update_operator_is_rejected():
    assert_rejected(
        'db.properties.updateOne({ "a": 1 }, { "$bit": { "b": 2 } })',
        STAGE_OPERATION,
        "$bit",
    )


@pytest.mark.parametrize("line", ["db.properties.find({}).skip(5)", "db.properties.find({}).count()"])
def test_unsupported_chained_calls_are_rejected(line):
    assert_rejected(line, STAGE_OPERATION, "is not permitted")


def test_limit_may_only_follow_find():
    assert_rejected(
        'db.properties.insertOne({ "a": 1 }).limit(5)',
        STAGE_OPERATION,
        "may only be chained onto",
    )


# --- stage 5: arity and argument shape -----------------------------------


@pytest.mark.parametrize(
    "line,fragment",
    [
        ('db.properties.updateOne({ "a": 1 })', "takes 2 to 3 argument(s), got 1"),
        ('db.properties.insertOne({ "a": 1 }, { "b": 2 }, { "c": 3 })', "takes 1 argument(s), got 3"),
        ('db.properties.find({}, {}, {})', "takes 0 to 2 argument(s), got 3"),
        ("db.properties.deleteOne()", "takes 1 to 2 argument(s), got 0"),
    ],
)
def test_wrong_argument_counts(line, fragment):
    assert_rejected(line, STAGE_ARITY, fragment)


def test_update_without_an_operator_would_replace_the_document():
    """The rule that stops a whole-document overwrite reaching production."""
    error = assert_rejected(
        'db.properties.updateOne({ "property_id": "PROP-1" }, { "listing_status": "sold" })',
        STAGE_ARITY,
        "replace the whole document",
    )
    assert "listing_status" in error.message


def test_update_as_an_aggregation_pipeline_is_rejected():
    assert_rejected(
        'db.properties.updateOne({ "a": 1 }, [{ "$set": { "b": 2 } }])',
        STAGE_ARITY,
        "aggregation pipeline",
    )


def test_empty_update_is_rejected():
    assert_rejected('db.properties.updateOne({ "a": 1 }, {})', STAGE_ARITY, "non-empty update")


def test_delete_with_an_empty_filter_is_rejected():
    """deleteMany({}) empties the collection. It has to be deliberate."""
    assert_rejected(
        "db.properties.deleteMany({})",
        STAGE_ARITY,
        "would delete every document",
    )


def test_insert_many_needs_an_array():
    assert_rejected(
        'db.properties.insertMany({ "a": 1 })',
        STAGE_ARITY,
        "array of documents",
    )


def test_insert_many_needs_at_least_one_document():
    assert_rejected("db.properties.insertMany([])", STAGE_ARITY, "at least one document")


def test_insert_document_with_an_operator_key_is_rejected():
    assert_rejected(
        'db.properties.insertOne({ "$set": { "a": 1 } })',
        STAGE_ARITY,
        "operator key",
    )


def test_empty_insert_is_rejected():
    assert_rejected("db.properties.insertOne({})", STAGE_ARITY, "non-empty document")


def test_filter_must_be_a_document():
    assert_rejected('db.properties.find("PROP-00042")', STAGE_ARITY, "must be a document")


def test_aggregate_needs_an_array():
    assert_rejected(
        'db.properties.aggregate({ "$match": {} })',
        STAGE_ARITY,
        "array of stages",
    )


def test_aggregate_needs_at_least_one_stage():
    assert_rejected("db.properties.aggregate([])", STAGE_ARITY, "at least one stage")


def test_aggregate_stage_with_two_operators_is_rejected():
    assert_rejected(
        'db.properties.aggregate([{ "$match": {}, "$limit": 5 }])',
        STAGE_ARITY,
        "exactly one operator",
    )


def test_lookup_missing_required_keys_names_them():
    error = assert_rejected(
        'db.properties.aggregate([{ "$lookup": { "from": "owners" } }])',
        STAGE_ARITY,
        "is missing",
    )
    assert "localField" in error.message and "as" in error.message


@pytest.mark.parametrize("value", ["0", "-1", '"10"', "1.5", "true"])
def test_limit_must_be_a_positive_whole_number(value):
    assert_rejected(
        "db.properties.find({}).limit(%s)" % value,
        STAGE_ARITY,
        "positive whole number",
    )


def test_sort_direction_must_be_one_or_minus_one():
    assert_rejected(
        'db.properties.find({}).sort({ "listing_price": "asc" })',
        STAGE_ARITY,
        "must be 1 or -1",
    )


def test_empty_sort_is_rejected():
    assert_rejected("db.properties.find({}).sort({})", STAGE_ARITY, "at least one field")


def test_sort_takes_one_argument():
    assert_rejected(
        'db.properties.find({}).sort({ "a": 1 }, { "b": 1 })',
        STAGE_ARITY,
        "exactly 1 argument",
    )
