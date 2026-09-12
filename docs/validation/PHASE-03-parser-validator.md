# Phase 3 - Parser and validator

**What this phase built:** the five validation checks, in two modules with no
I/O at all, and 110 tests.

## Variables used in this guide

Repeated here so the page stands alone; the full list, including the values AWS
generates, is in [README.md](README.md).

```bash
export PROJECT_ROOT=~/Documents/PROJECTS/mongo-dcu-pipeline
```

| Variable | Example value | Where it comes from |
|---|---|---|
| `PROJECT_ROOT` | `~/Documents/PROJECTS/mongo-dcu-pipeline` | Wherever you cloned the repository |

No AWS and no variables beyond the path: this phase is pure logic, with no
I/O anywhere in it. **`$set`, `$match`, `$graphLookup` and the rest are MongoDB
operators, not shell variables** - inside a query line they are literal text,
which is why every example quotes them.

Every command below is given in a variable form and again fully expanded.

## 1. The test suite

```bash
# variable form
cd $PROJECT_ROOT && .venv/bin/python -m pytest

# expanded
cd ~/Documents/PROJECTS/mongo-dcu-pipeline && .venv/bin/python -m pytest
```

Expect `110 passed` in well under a second. The speed is the evidence that
neither module touches a database, S3 or the filesystem.

If the virtual environment is missing:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install --requirement requirements-dev.txt
```

See the suite broken out by name:

```bash
.venv/bin/python -m pytest -v | head -40
```

## 2. Valid lines parse into real BSON types

```bash
cd $PROJECT_ROOT
.venv/bin/python - <<'PY'
from app.validator import validate_line

for line in [
    'db.properties.find({ "listing_status": "active" })',
    'db.properties.find({ state: "VA" }).sort({ listing_price: -1 }).limit(10);',
    'db.properties.insertOne({ "_id": ObjectId("64b7f1c2e1b2c3d4e5f60718"), "listed": ISODate("2026-01-15T00:00:00Z"), "price": NumberDecimal("450000.00") })',
]:
    q = validate_line(line)
    print(f"{q.operation:10} args={q.arguments}")
PY
```

Note the third line: `ObjectId`, `ISODate` and `NumberDecimal` come back as
`ObjectId`, `datetime` and `Decimal128` instances, not as dictionaries that
merely look right. Note the second: unquoted keys, a chained sort and limit,
and a trailing semicolon are all accepted, because that is what people type.

## 3. Each check rejects, with a message worth reading

```bash
.venv/bin/python - <<'PY'
from app.validator import validate_line

cases = [
    ("shape",      'select * from properties'),
    ("delimiters", 'db.properties.find({ "bedrooms": 4'),
    ("delimiters", 'db.properties.updateOne({ "a": 1 }, { "$set": { "b": 2 } )'),
    ("json",       'db.properties.find({ "_id": ObjectId("nope") })'),
    ("operation",  'db.properties.drop()'),
    ("operation",  'db.properties.aggregate([{ "$graphLookup": {} }])'),
    ("arity",      'db.properties.updateOne({ "property_id": "PROP-1" }, { "listing_status": "sold" })'),
    ("arity",      'db.properties.deleteMany({})'),
]
for expected, line in cases:
    try:
        validate_line(line)
        print(f"NOT REJECTED: {line}")
    except Exception as e:
        flag = "ok " if e.stage == expected else "??? "
        print(f"{flag}{e.stage:11} {e}")
PY
```

Every row should read `ok`. The two worth dwelling on:

**The missing brace** reports the *innermost* unclosed delimiter, so it points
at the brace that was forgotten rather than at the call's own parenthesis:

```
unbalanced '{' opened at col 20
```

**The bare-document update** is valid MongoDB that does not do what it looks
like - it *replaces* the matched document and discards every other field:

```
updateOne update must use update operators such as $set - a bare field
('listing_status') would replace the whole document
```

## 4. The allowlist is a compatibility control

Each of these works in MongoDB and is refused here, because production is
DocumentDB and the failure should have a reason attached rather than surface as
a driver error mid-file.

```bash
.venv/bin/python - <<'PY'
from app.validator import validate_line
for line in [
    'db.properties.aggregate([{ "$graphLookup": {} }])',
    'db.properties.aggregate([{ "$text": { "$search": "x" } }])',
    'db.properties.aggregate([{ "$lookup": { "from": "o", "let": {}, "pipeline": [] } }])',
    'db.properties.find({ "$where": "this.bedrooms > 3" })',
]:
    try:
        validate_line(line)
        print("NOT REJECTED:", line)
    except Exception as e:
        print("-", e)
PY
```

Each message should name the construct and say why it cannot be used.

## 5. Blank and comment lines are skipped, not failed

```bash
.venv/bin/python -c "
from app.parser import is_skippable
print([is_skippable(x) for x in ['', '   ', '// a note', '# another', 'db.properties.find({})']])
"
```

Expect `[True, True, True, True, False]`. A comment in a query file is a note
from whoever wrote it; failing the file over one would teach people to strip
their notes out.

## Pass criteria

- [ ] 110 tests pass in under a second
- [ ] Constructors produce real `ObjectId` / `datetime` / `Decimal128` values
- [ ] Each of the five checks rejects at the expected stage
- [ ] The missing-brace message names the column the brace opened at
- [ ] The bare-document update and the empty delete filter are both refused
- [ ] Blanks and comments are skipped
