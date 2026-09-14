#!/usr/bin/env python3
"""Apply sql/schema.sql to the shared MySQL instance.

Called by ansible/playbooks/rds-schema.yml. The schema is written to be rerun -
CREATE ... IF NOT EXISTS throughout - so applying it to an instance that
already has the tables changes nothing, and the output says so.

A script rather than community.mysql.mysql_db, whose import mode shells out to
the mysql command-line client this project does not install. PyMySQL with
multi-statement execution enabled runs the file the way the client would.

Connection details are read from the environment, never from arguments, where
`ps` would show them.

    MYSQL_HOST=... MYSQL_USER=... MYSQL_PASSWORD=... MYSQL_DATABASE=mongo_dcu \\
        python apply_schema.py sql/schema.sql

Prints one JSON object: the tables before, the tables after, and which were
created.
"""

from __future__ import annotations

import json
import os
import sys

import pymysql
from pymysql.constants import CLIENT


def table_names(cursor: pymysql.cursors.Cursor, database: str) -> list[str]:
    cursor.execute(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema = %s ORDER BY table_name",
        (database,),
    )
    return [row[0] for row in cursor.fetchall()]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: apply_schema.py <schema.sql>", file=sys.stderr)
        return 2

    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        sql = handle.read()

    database = os.environ["MYSQL_DATABASE"]
    connection = pymysql.connect(
        host=os.environ["MYSQL_HOST"],
        port=int(os.environ.get("MYSQL_PORT", "3306")),
        user=os.environ["MYSQL_USER"],
        password=os.environ["MYSQL_PASSWORD"],
        connect_timeout=10,
        autocommit=True,
        client_flag=CLIENT.MULTI_STATEMENTS,
    )
    try:
        with connection.cursor() as cursor:
            before = table_names(cursor, database)
            cursor.execute(sql)
            # A multi-statement execute returns after the first statement. The
            # remaining results have to be drained, or the next query on this
            # connection fails with "commands out of sync".
            while cursor.nextset():
                pass
            after = table_names(cursor, database)
    finally:
        connection.close()

    print(json.dumps({
        "before": before,
        "after": after,
        "created": sorted(set(after) - set(before)),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
