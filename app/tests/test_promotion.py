"""Tests for the promotion gate's rules.

These are the checks standing between a validated qa file and production, so
each one is tested failing on its own - a gate that only ever reports "denied"
is a gate nobody can use.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone

from app.promotion import TokenRecord, gate_failures, issue_token, prod_refusal

NOW = datetime(2026, 9, 15, 12, 0, 0)
HASH = "a" * 64


def valid_record(**overrides) -> TokenRecord:
    fields = dict(
        run_id="qa-run-1",
        environment="qa",
        status="success",
        file_hash=HASH,
        token_expires_at=NOW + timedelta(hours=1),
        token_used=False,
    )
    fields.update(overrides)
    return TokenRecord(**fields)


def test_issued_token_is_16_hex_characters_and_expires_after_the_ttl():
    now = datetime(2026, 9, 15, 12, 0, tzinfo=timezone.utc)
    token, expires_at = issue_token(now, 24)
    assert re.fullmatch(r"[0-9a-f]{16}", token)
    assert expires_at == now + timedelta(hours=24)


def test_every_issued_token_is_different():
    tokens = {issue_token(NOW, 24)[0] for _ in range(50)}
    assert len(tokens) == 50


def test_prod_runs_a_promoted_file_it_has_not_run():
    assert prod_refusal([], "qa-run-1") is None


def test_prod_refuses_a_file_that_was_never_promoted():
    reason = prod_refusal([], None)
    assert "no promotion authorises this file" in reason


def test_prod_refuses_a_file_it_has_already_run_even_when_promoted_again():
    reason = prod_refusal(["prod-run-1"], "qa-run-2")
    assert "already run in prod" in reason
    assert "prod-run-1" in reason


def test_a_valid_token_and_file_pass_every_check():
    assert gate_failures(valid_record(), HASH, NOW) == []


def test_an_unknown_token_is_named():
    assert gate_failures(None, HASH, NOW) == ["token: no run carries this token"]


def test_each_check_fails_on_its_own():
    cases = {
        "environment:": valid_record(environment="prod"),
        "status:": valid_record(status="failed"),
        "hash:": valid_record(file_hash="b" * 64),
        "used:": valid_record(token_used=True),
        "expired:": valid_record(token_expires_at=NOW - timedelta(seconds=1)),
    }
    for name, record in cases.items():
        failures = gate_failures(record, HASH, NOW)
        assert len(failures) == 1, (name, failures)
        assert failures[0].startswith(name)


def test_a_token_expiring_exactly_now_is_expired():
    failures = gate_failures(valid_record(token_expires_at=NOW), HASH, NOW)
    assert failures[0].startswith("expired:")


def test_every_failing_check_is_reported_not_just_the_first():
    record = valid_record(file_hash="b" * 64, token_used=True, token_expires_at=None)
    names = [failure.split(":")[0] for failure in gate_failures(record, HASH, NOW)]
    assert names == ["hash", "used", "expired"]
