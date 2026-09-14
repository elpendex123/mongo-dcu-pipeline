"""The promotion gate's rules, as pure functions.

A file reaches production only after a byte-identical, fully successful qa run,
and only through that run's token - once, and before it expires. The rules live
here, with no database and no S3, so they can be tested on their own. The
application (issuing a token, refusing a file prod must not run) and
scripts/promotion_gate.py (checking and claiming a token) both call this module
rather than each keeping its own copy of what "valid" means.
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta

# 8 bytes, 16 hex characters. Guessing a token is not the attack the gate has
# to resist: one is honoured only together with the exact file it was issued
# for, once, before it expires, and only by someone who can already reach the
# run history database.
TOKEN_BYTES = 8


def issue_token(now: datetime, ttl_hours: int) -> tuple[str, datetime]:
    """A new single-use token, and the moment it stops being honoured."""
    return secrets.token_hex(TOKEN_BYTES), now + timedelta(hours=ttl_hours)


def prod_refusal(
    prior_prod_run_ids: list[str], authorising_qa_run_id: str | None
) -> str | None:
    """Why production must not run a file, or None if it may.

    Args:
        prior_prod_run_ids: earlier production runs of a file with the same
            hash, refused ones excluded. A run still marked running counts: it
            is a run that was interrupted part way, and may have applied some
            of its writes.
        authorising_qa_run_id: the qa run whose token promoted a file with this
            hash, if there is one.
    """
    if prior_prod_run_ids:
        return (
            f"this file has already run in prod (run {prior_prod_run_ids[0]}) - a file "
            "runs in production once, and running its writes a second time is a data "
            "problem, not a retry"
        )
    if authorising_qa_run_id is None:
        return (
            "no promotion authorises this file - it has to pass qa in full and be "
            "promoted with that run's token by scripts/promote.sh; a file put in the "
            "prod input bucket any other way is never run"
        )
    return None


@dataclass(frozen=True)
class TokenRecord:
    """The run a submitted token belongs to, as the gate reads it from MySQL."""

    run_id: str
    environment: str
    status: str
    file_hash: str
    token_expires_at: datetime | None
    token_used: bool


def gate_failures(record: TokenRecord | None, file_hash: str, now: datetime) -> list[str]:
    """Every check the submitted file and token fail, each named.

    All of them, not the first: "the hash does not match, and the token has
    expired" tells the person running the promotion that resubmitting the
    right file will not be enough on its own.

    Args:
        record: the run carrying the token, or None if no run does.
        file_hash: SHA-256 of the file being submitted for promotion.
        now: naive UTC, the same convention token_expires_at is stored in.
    """
    if record is None:
        return ["token: no run carries this token"]

    failures: list[str] = []
    if record.environment != "qa":
        failures.append(
            f"environment: the token belongs to a {record.environment} run, not a qa run"
        )
    if record.status != "success":
        failures.append(f"status: qa run {record.run_id} ended {record.status}, not success")
    if record.file_hash != file_hash:
        failures.append(
            f"hash: the submitted file is sha256 {file_hash} but qa run {record.run_id} "
            f"validated {record.file_hash} - the file has changed since it passed"
        )
    if record.token_used:
        failures.append("used: the token has already promoted a file, and is honoured once")
    if record.token_expires_at is None:
        failures.append("expired: the run has no token expiry recorded")
    elif record.token_expires_at <= now:
        failures.append(f"expired: the token expired at {record.token_expires_at:%Y-%m-%d %H:%M:%S} UTC")
    return failures
