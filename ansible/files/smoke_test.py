#!/usr/bin/env python3
"""In-cluster connectivity checks, run as a Job before anything is deployed.

Run by ansible/playbooks/smoke-tests.yml under the application's own service
account, with the application's own Secrets, from the application's own image.
A pass means the application pod will be able to do the same thing.

Each check prints one JSON line - {"check", "ok", "detail", "ms"} - which the
playbook reads back from the pod log. A failing check is a result, not a crash:
every check runs, and the process exits non-zero at the end if any failed.

Environment:
    MONGO_URI                 from the docdb Secret
    MYSQL_HOST/_PORT/_USER/_PASSWORD/_DATABASE   from the rds Secret
    MONGO_DATABASE            database to write the scratch document in
    EXPECTED_ROLE_ARN         the IRSA role the pod should be running as
    OWN_BUCKET                a bucket the role should reach
    FOREIGN_BUCKET            a bucket belonging to another environment
    OWN_SECRET                a secret the role should be able to read
"""

from __future__ import annotations

import ipaddress
import json
import os
import signal
import socket
import sys
import time
import urllib.parse
import urllib.request
from typing import Callable

RESULTS: list[dict] = []

# Every check is cut off after this long. Client libraries retry and wait on
# their own schedules - botocore's defaults allow a single unreachable endpoint
# to hold a call for minutes - and one hung check must not silently consume the
# Job's whole deadline and take every later check's result with it.
CHECK_TIMEOUT_SECONDS = 15


class CheckTimedOut(Exception):
    pass


def _on_alarm(signum, frame):  # noqa: ARG001 - signal handler signature
    raise CheckTimedOut(f"no answer within {CHECK_TIMEOUT_SECONDS}s")


def run(name: str, check: Callable[[], str]) -> None:
    started = time.monotonic()
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(CHECK_TIMEOUT_SECONDS)
    try:
        detail, ok = check(), True
    except Exception as exc:  # noqa: BLE001 - every failure is reported, not raised
        detail, ok = f"{type(exc).__name__}: {exc}", False
    finally:
        signal.alarm(0)
    result = {
        "check": name,
        "ok": ok,
        "detail": detail,
        "ms": round((time.monotonic() - started) * 1000),
    }
    RESULTS.append(result)
    print(json.dumps(result), flush=True)


# ----------------------------------------------------------------- network

def resolves_privately(host: str) -> str:
    addresses = sorted({info[4][0] for info in socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)})
    public = [a for a in addresses if not ipaddress.ip_address(a).is_private]
    if public:
        # The symptom of peering DNS resolution being off: the name resolves to
        # the instance's public address, and a VPC with no internet route
        # times out trying to reach it over a peering link that is working.
        raise RuntimeError(f"{host} resolved to public {public} - this VPC has no route to a public address")
    return f"{host} -> {', '.join(addresses)}"


def port_open(host: str, port: int) -> str:
    with socket.create_connection((host, port), timeout=5):
        return f"{host}:{port} accepted a connection"


# -------------------------------------------------------------- DocumentDB

def documentdb_tls() -> str:
    from pymongo import MongoClient

    client = MongoClient(os.environ["MONGO_URI"], serverSelectionTimeoutMS=8000)
    try:
        client.admin.command("ping")
        version = client.server_info().get("version", "?")
        return f"TLS handshake verified against the RDS CA bundle, server {version}"
    finally:
        client.close()


def documentdb_write() -> str:
    # The connection string sets retryWrites=false, which DocumentDB requires.
    # Get that wrong and connecting and reading still work - the first write is
    # what fails, so a write is what this checks.
    from pymongo import MongoClient

    client = MongoClient(os.environ["MONGO_URI"], serverSelectionTimeoutMS=8000)
    try:
        database = client[os.environ.get("MONGO_DATABASE", "mongo_dcu")]
        scratch = database["_smoke_test"]
        inserted = scratch.insert_one({"written_by": "smoke-test", "at": time.time()}).inserted_id
        found = scratch.count_documents({"_id": inserted})
        database.drop_collection("_smoke_test")
        if found != 1:
            raise RuntimeError(f"inserted {inserted} but read back {found} documents")
        return "inserted, read back and dropped a scratch document"
    finally:
        client.close()


# ------------------------------------------------------------------- MySQL

def mysql_schema() -> str:
    import pymysql

    connection = pymysql.connect(
        host=os.environ["MYSQL_HOST"],
        port=int(os.environ.get("MYSQL_PORT", "3306")),
        user=os.environ["MYSQL_USER"],
        password=os.environ["MYSQL_PASSWORD"],
        database=os.environ["MYSQL_DATABASE"],
        connect_timeout=8,
    )
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT VERSION()")
            version = cursor.fetchone()[0]
            cursor.execute(
                "SELECT table_name FROM information_schema.tables "
                "WHERE table_schema = DATABASE() ORDER BY table_name"
            )
            tables = [row[0] for row in cursor.fetchall()]
    finally:
        connection.close()
    missing = sorted({"runs", "run_lines", "email_notifications"} - set(tables))
    if missing:
        raise RuntimeError(f"connected to MySQL {version} but missing {missing} - run playbooks/rds-schema.yml")
    return f"MySQL {version}: {', '.join(tables)}"


# ------------------------------------------------------------ AWS via IRSA

def irsa_identity() -> str:
    if not os.environ.get("AWS_WEB_IDENTITY_TOKEN_FILE"):
        raise RuntimeError(
            "no web identity token was injected - the service account is not annotated "
            "with a role, or the pod is not using that service account"
        )
    import boto3

    arn = boto3.client("sts").get_caller_identity()["Arn"]
    expected = os.environ["EXPECTED_ROLE_ARN"].rsplit("/", 1)[-1]
    if f":assumed-role/{expected}/" not in arn:
        raise RuntimeError(f"running as {arn}, expected the {expected} role")
    return arn


def own_bucket() -> str:
    import boto3

    bucket = os.environ["OWN_BUCKET"]
    response = boto3.client("s3").list_objects_v2(Bucket=bucket, MaxKeys=5)
    return f"listed {bucket}: {response.get('KeyCount', 0)} object(s) in the first page"


def foreign_bucket() -> str:
    import boto3
    from botocore.exceptions import ClientError

    bucket = os.environ["FOREIGN_BUCKET"]
    try:
        boto3.client("s3").list_objects_v2(Bucket=bucket, MaxKeys=1)
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code == "AccessDenied":
            return f"{bucket}: AccessDenied, as it should be"
        if code == "NoSuchBucket":
            return f"{bucket} does not exist, so denial could not be observed - inconclusive, not a failure"
        raise
    raise RuntimeError(f"listed {bucket} - the role reaches beyond its own environment")


def own_secret() -> str:
    import boto3

    name = os.environ["OWN_SECRET"]
    value = boto3.client("secretsmanager").get_secret_value(SecretId=name)["SecretString"]
    return f"read {name} through the Secrets Manager endpoint ({len(value)} characters, not printed)"


def node_credentials_unreachable() -> str:
    # The launch template sets the metadata hop limit to 1. A pod is one hop
    # further from the metadata service than the node is, so the token response
    # never reaches it - and without a token there is no way to the node role.
    request = urllib.request.Request(
        "http://169.254.169.254/latest/api/token",
        method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
    )
    try:
        with urllib.request.urlopen(request, timeout=3):
            pass
    except Exception as exc:  # noqa: BLE001 - any failure to get a token is the pass condition
        return f"metadata token request failed ({type(exc).__name__}) - the node role is out of reach"
    raise RuntimeError("the pod obtained a metadata token - it can read the node role's credentials")


def main() -> int:
    mongo_host = urllib.parse.urlsplit(os.environ["MONGO_URI"]).hostname or ""
    mysql_host = os.environ["MYSQL_HOST"]
    mysql_port = int(os.environ.get("MYSQL_PORT", "3306"))

    run("documentdb name resolves to a private address", lambda: resolves_privately(mongo_host))
    run("documentdb port 27017 reachable", lambda: port_open(mongo_host, 27017))
    run("documentdb TLS and ping", documentdb_tls)
    run("documentdb write with retryWrites=false", documentdb_write)
    run("mysql name resolves to a private address across the peering", lambda: resolves_privately(mysql_host))
    run("mysql port reachable across the peering", lambda: port_open(mysql_host, mysql_port))
    run("mysql schema present", mysql_schema)
    run("IRSA credentials are the application role", irsa_identity)
    run("S3: own input bucket readable", own_bucket)
    run("S3: another environment's bucket denied", foreign_bucket)
    run("Secrets Manager: own secret readable", own_secret)
    run("node role credentials unreachable from the pod", node_credentials_unreachable)

    failed = [r["check"] for r in RESULTS if not r["ok"]]
    print(json.dumps({"summary": True, "passed": len(RESULTS) - len(failed), "failed": failed}), flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
