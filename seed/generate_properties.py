#!/usr/bin/env python3
"""Generate the 100 seed documents, deterministically.

Run once to produce properties.json, which is committed. Regenerating it with
the same seed produces byte-identical output, so a change to the seed data is
visible as a real diff rather than as a hundred lines of noise.

The domain is real estate and mortgage listings, and every document has the
same shape so that a query written against one works against all of them.

    python3 seed/generate_properties.py
"""

from __future__ import annotations

import os
import random
from datetime import datetime, timedelta, timezone

from bson import Decimal128, ObjectId, json_util

SEED = 20260910
DOCUMENT_COUNT = 100

# Northern Virginia, Maryland and DC - the market a Freddie Mac dataset would
# actually cover.
LOCATIONS = [
    ("Reston", "VA", "20190"),
    ("McLean", "VA", "22101"),
    ("Arlington", "VA", "22201"),
    ("Alexandria", "VA", "22314"),
    ("Vienna", "VA", "22180"),
    ("Fairfax", "VA", "22030"),
    ("Herndon", "VA", "20170"),
    ("Bethesda", "MD", "20814"),
    ("Rockville", "MD", "20850"),
    ("Silver Spring", "MD", "20910"),
    ("Washington", "DC", "20001"),
    ("Washington", "DC", "20016"),
]

STREET_NAMES = [
    "Sunset", "Oak Hill", "Maple", "Cedar Ridge", "Birchwood", "Willow Creek",
    "Chestnut", "Dogwood", "Magnolia", "Laurel", "Juniper", "Hawthorn",
    "Sycamore", "Poplar", "Alder", "Hickory",
]
STREET_TYPES = ["Ln", "Ct", "Dr", "Ave", "Rd", "Way", "Ter", "Pl"]

PROPERTY_TYPES = ["single_family", "condo", "townhouse", "multi_family"]
PROPERTY_TYPE_WEIGHTS = [45, 25, 22, 8]

LISTING_STATUSES = ["active", "pending", "sold", "off_market"]
LISTING_STATUS_WEIGHTS = [40, 15, 35, 10]

LOAN_TYPES = ["conventional", "FHA", "VA", "jumbo"]
LOAN_TYPE_WEIGHTS = [55, 18, 17, 10]

FIRST_NAMES = [
    "Alice", "Marcus", "Priya", "Daniel", "Sofia", "Andre", "Mei", "Jonas",
    "Rosa", "Ibrahim", "Nora", "Victor", "Leah", "Thomas", "Amara", "Felix",
]
LAST_NAMES = [
    "Whitfield", "Okonkwo", "Ramirez", "Kowalski", "Nakamura", "Bergstrom",
    "Delacroix", "Santos", "Ahmadi", "Lindqvist", "Moreau", "Castellano",
    "Ferreira", "Novak", "Petrov", "Hartley",
]

REFERENCE_DATE = datetime(2026, 9, 1, tzinfo=timezone.utc)


def money(value: float) -> Decimal128:
    """Prices as Decimal128 rather than float.

    Currency held as a binary float accumulates rounding error the moment it is
    summed, which an aggregation over listing_price does immediately.
    """
    return Decimal128(f"{value:.2f}")


def build_document(index: int, rng: random.Random) -> dict:
    city, state, zip_code = rng.choice(LOCATIONS)
    property_type = rng.choices(PROPERTY_TYPES, weights=PROPERTY_TYPE_WEIGHTS)[0]
    listing_status = rng.choices(LISTING_STATUSES, weights=LISTING_STATUS_WEIGHTS)[0]

    if property_type == "condo":
        bedrooms = rng.randint(1, 3)
        square_feet = rng.randint(650, 1800)
        lot_size = 0.0
    elif property_type == "townhouse":
        bedrooms = rng.randint(2, 4)
        square_feet = rng.randint(1200, 2600)
        lot_size = round(rng.uniform(0.03, 0.12), 3)
    elif property_type == "multi_family":
        bedrooms = rng.randint(4, 8)
        square_feet = rng.randint(2400, 5200)
        lot_size = round(rng.uniform(0.15, 0.6), 3)
    else:
        bedrooms = rng.randint(3, 6)
        square_feet = rng.randint(1600, 4800)
        lot_size = round(rng.uniform(0.12, 1.1), 3)

    bathrooms = round(rng.uniform(1.0, min(bedrooms + 0.5, 5.0)) * 2) / 2
    year_built = rng.randint(1948, 2025)

    price_per_sqft = rng.uniform(280, 620)
    listing_price = round(square_feet * price_per_sqft, -2)

    # A sold or off-market listing usually has a sale behind it; an active one
    # may or may not, which is what makes "last_sold_price": null a case a
    # query has to cope with.
    has_sale = listing_status in ("sold", "off_market") or rng.random() < 0.55
    if has_sale:
        days_ago = rng.randint(90, 3600)
        last_sold_date = REFERENCE_DATE - timedelta(days=days_ago)
        last_sold_price = round(listing_price * rng.uniform(0.62, 0.97), -2)
    else:
        last_sold_date = None
        last_sold_price = None

    loan_type = rng.choices(LOAN_TYPES, weights=LOAN_TYPE_WEIGHTS)[0]
    down_payment_fraction = {
        "conventional": rng.uniform(0.10, 0.25),
        "FHA": rng.uniform(0.035, 0.10),
        "VA": rng.uniform(0.0, 0.05),
        "jumbo": rng.uniform(0.20, 0.35),
    }[loan_type]
    loan_amount = round(listing_price * (1 - down_payment_fraction), -2)

    created_days_ago = rng.randint(5, 400)
    created_at = REFERENCE_DATE - timedelta(days=created_days_ago)
    updated_at = created_at + timedelta(days=rng.randint(0, created_days_ago))

    return {
        # Deterministic ids, so reseeding produces the same documents and a
        # query written against a specific _id keeps working.
        "_id": ObjectId(f"{index:024x}"),
        "property_id": f"PROP-{index:05d}",
        "address": {
            "street": f"{rng.randint(100, 9899)} {rng.choice(STREET_NAMES)} {rng.choice(STREET_TYPES)}",
            "city": city,
            "state": state,
            "zip": zip_code,
        },
        "property_type": property_type,
        "bedrooms": bedrooms,
        "bathrooms": bathrooms,
        "square_feet": square_feet,
        "lot_size_acres": lot_size,
        "year_built": year_built,
        "listing_status": listing_status,
        "listing_price": money(listing_price),
        "last_sold_price": money(last_sold_price) if last_sold_price else None,
        "last_sold_date": last_sold_date,
        "mortgage": {
            "loan_type": loan_type,
            "loan_amount": money(loan_amount),
            "interest_rate": round(rng.uniform(4.75, 7.85), 3),
            "term_years": rng.choice([15, 20, 30, 30, 30]),
        },
        "current_owner": f"{rng.choice(FIRST_NAMES)} {rng.choice(LAST_NAMES)}",
        "tax_assessed_value": money(round(listing_price * rng.uniform(0.78, 1.04), -2)),
        "created_at": created_at,
        "updated_at": updated_at,
    }


def main() -> None:
    rng = random.Random(SEED)
    documents = [build_document(index, rng) for index in range(1, DOCUMENT_COUNT + 1)]

    output_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "properties.json")
    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write(json_util.dumps(documents, indent=2))
        handle.write("\n")

    print(f"wrote {len(documents)} documents to {output_path}")


if __name__ == "__main__":
    main()
