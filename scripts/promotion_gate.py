#!/usr/bin/env python3
"""The promotion gate's database half. Called by scripts/promote.sh.

    promotion_gate.py check   <token> <sha256>   names every failing check; changes nothing
    promotion_gate.py claim   <token> <sha256>   marks the token used; prints the qa run id
    promotion_gate.py release <token>            un-marks it, after a failed copy to prod

The rules themselves are app/promotion.py, shared with the application. This
script reads MySQL and applies them.

claim re-checks everything inside a single conditional UPDATE and requires it
to change exactly one row. Two promotions racing on one token both pass check;
only one of them can change the row.

Connection details come from the environment - MYSQL_HOST, MYSQL_PORT,
MYSQL_USER, MYSQL_PASSWORD, MYSQL_DATABASE - never from arguments, where `ps`
would show them.

Exit status: 0 passed, 1 a check failed, 2 a usage or connection error.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

import pymysql

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.promotion import TokenRecord, gate_failures  # noqa: E402

TOKEN_PATTERN = re.compile(r"[0-9a-f]{16}")
HASH_PATTERN = re.compile(r"[0-9a-f]{64}")


def connect() -> pymysql.connections.Connection:
    return pymysql.connect(
        host=os.environ["MYSQL_HOST"],
        port=int(os.environ.get("MYSQL_PORT", "3306")),
        user=os.environ["MYSQL_USER"],
        password=os.environ["MYSQL_PASSWORD"],
        database=os.environ["MYSQL_DATABASE"],
        connect_timeout=10,
        autocommit=True,
    )


def read_record(cursor, token: str) -> TokenRecord | None:
    cursor.execute(
        """
        SELECT run_id, environment, status, file_hash, token_expires_at, token_used
          FROM runs
         WHERE promotion_token = %s
        """,
        (token,),
    )
    row = cursor.fetchone()
    if row is None:
        return None
    run_id, environment, status, file_hash, expires_at, used = row
    return TokenRecord(run_id, environment, status, file_hash, expires_at, bool(used))


def database_now(cursor):
    # The database's clock, not this machine's: claim compares against
    # UTC_TIMESTAMP(), and check has to agree with claim about what "expired"
    # means.
    cursor.execute("SELECT UTC_TIMESTAMP()")
    return cursor.fetchone()[0]


def check(cursor, token: str, file_hash: str) -> int:
    record = read_record(cursor, token)
    failures = gate_failures(record, file_hash, database_now(cursor))
    if failures:
        for failure in failures:
            print(f"  FAIL {failure}")
        return 1
    print(
        f"  ok   every check passed: qa run {record.run_id} succeeded on this exact file, "
        f"token unused, expires {record.token_expires_at:%Y-%m-%d %H:%M:%S} UTC"
    )
    return 0


def claim(cursor, token: str, file_hash: str) -> int:
    changed = cursor.execute(
        """
        UPDATE runs
           SET token_used = TRUE
         WHERE promotion_token = %s
           AND file_hash = %s
           AND environment = 'qa'
           AND status = 'success'
           AND token_used = FALSE
           AND token_expires_at > UTC_TIMESTAMP()
        """,
        (token, file_hash),
    )
    if changed != 1:
        print(
            "claim refused: no unused, unexpired token for this file - it was used or "
            "expired between the check and the claim",
            file=sys.stderr,
        )
        return 1
    print(read_record(cursor, token).run_id)
    return 0


def release(cursor, token: str) -> int:
    changed = cursor.execute(
        "UPDATE runs SET token_used = FALSE WHERE promotion_token = %s AND token_used = TRUE",
        (token,),
    )
    if changed != 1:
        print("release changed nothing - the token was not marked used", file=sys.stderr)
        return 1
    return 0


def main(argv: list[str]) -> int:
    usage = "usage: promotion_gate.py check|claim <token> <sha256>  |  release <token>"
    if len(argv) < 2 or argv[0] not in ("check", "claim", "release"):
        print(usage, file=sys.stderr)
        return 2

    command, token = argv[0], argv[1]
    file_hash = argv[2] if len(argv) > 2 else ""

    if not TOKEN_PATTERN.fullmatch(token):
        print(f"token must be 16 lowercase hex characters, as issued - got {token!r}", file=sys.stderr)
        return 2
    if command != "release" and not HASH_PATTERN.fullmatch(file_hash):
        print(f"{usage}\nsha256 must be 64 lowercase hex characters", file=sys.stderr)
        return 2

    try:
        connection = connect()
    except (KeyError, pymysql.MySQLError) as error:
        print(f"cannot connect to run history: {error}", file=sys.stderr)
        return 2

    try:
        with connection.cursor() as cursor:
            if command == "check":
                return check(cursor, token, file_hash)
            if command == "claim":
                return claim(cursor, token, file_hash)
            return release(cursor, token)
    finally:
        connection.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
