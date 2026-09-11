"""S3 access: finding work, fetching it, and routing it when it is done.

Real S3 in every environment, local development included. The pickup, move and
upload paths are the ones most likely to behave differently against a stand-in,
and storage for a handful of small text files costs a fraction of a cent per
month - so there is nothing to gain from faking it.
"""

from __future__ import annotations

import hashlib
import os

import boto3
from botocore.exceptions import ClientError

from .logger import get_logger

log = get_logger("s3")

_HASH_CHUNK_BYTES = 1024 * 1024


class S3Client:
    """The pipeline's view of S3, in its own vocabulary rather than boto3's."""

    def __init__(self, region: str, endpoint_url: str | None = None) -> None:
        self._client = boto3.client("s3", region_name=region, endpoint_url=endpoint_url)

    def list_input_files(self, bucket: str) -> list[str]:
        """Keys awaiting processing, oldest first.

        Ordered by last-modified so a backlog is worked through in the order it
        arrived rather than alphabetically, which would let a file named
        earlier in the alphabet jump a queue it joined later.
        """
        paginator = self._client.get_paginator("list_objects_v2")
        entries: list[tuple[str, float]] = []

        for page in paginator.paginate(Bucket=bucket):
            for item in page.get("Contents", []):
                key = item["Key"]
                # A key ending in / is a folder marker from a console upload,
                # not a file.
                if key.endswith("/"):
                    continue
                entries.append((key, item["LastModified"].timestamp()))

        entries.sort(key=lambda entry: entry[1])
        return [key for key, _ in entries]

    def download(self, bucket: str, key: str, destination: str) -> str:
        """Download an object and return the SHA-256 of its bytes.

        The hash is computed here, from the bytes actually processed, because
        it is what the promotion gate later compares against. Hashing the file
        the pipeline really read - rather than trusting a hash computed
        elsewhere - is what makes "byte-identical to what QA validated" a
        claim rather than an assumption.
        """
        os.makedirs(os.path.dirname(destination) or ".", exist_ok=True)
        self._client.download_file(bucket, key, destination)

        digest = hashlib.sha256()
        with open(destination, "rb") as handle:
            for chunk in iter(lambda: handle.read(_HASH_CHUNK_BYTES), b""):
                digest.update(chunk)

        file_hash = digest.hexdigest()
        log.info(
            "downloaded file",
            bucket=bucket,
            key=key,
            bytes=os.path.getsize(destination),
            file_hash=file_hash,
        )
        return file_hash

    def move(self, key: str, source_bucket: str, destination_bucket: str) -> None:
        """Move an object between buckets.

        S3 has no move. This is a server-side copy followed by a delete, and
        the delete only runs if the copy succeeded - so a failure leaves the
        file in the input bucket to be retried, rather than losing it.
        """
        self._client.copy_object(
            Bucket=destination_bucket,
            Key=key,
            CopySource={"Bucket": source_bucket, "Key": key},
        )
        self._client.delete_object(Bucket=source_bucket, Key=key)

        log.info(
            "moved file",
            key=key,
            source_bucket=source_bucket,
            destination_bucket=destination_bucket,
        )

    def upload_text(self, bucket: str, key: str, body: str, content_type: str) -> None:
        self._client.put_object(
            Bucket=bucket,
            Key=key,
            Body=body.encode("utf-8"),
            ContentType=content_type,
        )
        log.info("uploaded object", bucket=bucket, key=key, bytes=len(body.encode("utf-8")))

    def check_access(self, buckets: list[str]) -> list[str]:
        """Which of these buckets cannot be reached.

        Run at startup. A missing bucket or a permissions gap should be a clear
        message at boot, not a file that vanishes mid-run twenty minutes later.
        """
        unreachable = []
        for bucket in buckets:
            try:
                self._client.head_bucket(Bucket=bucket)
            except ClientError as error:
                code = error.response.get("Error", {}).get("Code", "unknown")
                log.error("bucket is not reachable", bucket=bucket, code=code)
                unreachable.append(bucket)
        return unreachable
