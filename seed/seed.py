#!/usr/bin/env python3
"""Reset the properties collection: drop, recreate indexes, reload.

The collection is dropped rather than emptied. Deleting documents leaves the
indexes behind, so an index added during an experiment would survive a "reset"
and quietly change how later queries perform. Dropping resets both.

One operation, safe to run whenever the data has been made a mess of during
testing. This is also what the Ansible documentdb-reset play calls.

    python3 seed/seed.py
    MONGO_URI=mongodb://localhost:27017 python3 seed/seed.py
"""

from __future__ import annotations

import os
import sys

from bson import json_util
from pymongo import ASCENDING, MongoClient

DEFAULT_URI = "mongodb://localhost:27017"
DEFAULT_DATABASE = "mongo_dcu"
DEFAULT_COLLECTION = "properties"

# Indexes the sample queries rely on. Deliberately ordinary: no wildcard, text
# or geospatial indexes, which DocumentDB either does not support or supports
# differently, and which would make local behaviour a poor guide to QA.
INDEXES = [
    ([("property_id", ASCENDING)], {"unique": True, "name": "uq_property_id"}),
    ([("listing_status", ASCENDING)], {"name": "idx_listing_status"}),
    (
        [("address.state", ASCENDING), ("address.city", ASCENDING)],
        {"name": "idx_address_state_city"},
    ),
    ([("listing_price", ASCENDING)], {"name": "idx_listing_price"}),
    ([("property_type", ASCENDING)], {"name": "idx_property_type"}),
]


def main() -> int:
    uri = os.getenv("MONGO_URI", DEFAULT_URI)
    database_name = os.getenv("MONGO_DATABASE", DEFAULT_DATABASE)
    collection_name = os.getenv("MONGO_COLLECTION", DEFAULT_COLLECTION)

    seed_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "properties.json")
    with open(seed_path, "r", encoding="utf-8") as handle:
        documents = json_util.loads(handle.read())

    print(f"connecting to {_redact(uri)}")
    client = MongoClient(uri, serverSelectionTimeoutMS=10000)
    client.admin.command("ping")

    database = client[database_name]

    print(f"dropping {database_name}.{collection_name}")
    database.drop_collection(collection_name)

    collection = database[collection_name]

    for keys, options in INDEXES:
        collection.create_index(keys, **options)
    print(f"created {len(INDEXES)} indexes")

    collection.insert_many(documents)
    print(f"inserted {collection.count_documents({})} documents")

    client.close()
    return 0


def _redact(uri: str) -> str:
    """Hide the password in a connection string before printing it."""
    if "@" not in uri:
        return uri
    scheme, _, rest = uri.partition("://")
    _, _, host = rest.partition("@")
    return f"{scheme}://***:***@{host}"


if __name__ == "__main__":
    sys.exit(main())
