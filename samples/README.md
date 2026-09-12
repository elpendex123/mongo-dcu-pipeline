# Sample query files

Drop any of these into the input bucket to exercise a path through the
pipeline.

## Variables used on this page

```bash
export S3_INPUT_BUCKET=mongo-dcu-pipeline-dev-input-950639281723
export MONGO_URI=mongodb://localhost:27017
```

| Variable | Example value | Where it comes from |
|---|---|---|
| `S3_INPUT_BUCKET` | `mongo-dcu-pipeline-dev-input-950639281723` | `terraform -chdir=terraform/environments/dev output -raw env_file_lines`. Also in `.env`. The trailing number is the AWS account ID |
| `MONGO_URI` | `mongodb://localhost:27017` | The local Compose container, from outside it. **From inside** the app container it is `mongodb://mongo:27017` - the service name, not localhost |

In qa and prod `MONGO_URI` is a DocumentDB endpoint instead - a generated
hostname of the form
`mongo-dcu-pipeline-docdb-qa.cluster-cxyz123abc45.us-east-1.docdb.amazonaws.com`,
where the middle portion is assigned by AWS at cluster creation and cannot be
predicted. It is read from a Terraform output and stored in Secrets Manager,
never typed.

```bash
# variable form
aws s3 cp samples/all-good.txt s3://$S3_INPUT_BUCKET/

# expanded
aws s3 cp samples/all-good.txt s3://mongo-dcu-pipeline-dev-input-950639281723/
```

| File | Exercises | Ends in |
|---|---|---|
| `all-good.txt` | Reads, aggregations and writes that all succeed | `-successful` |
| `one-bad-line.txt` | A single missing closing brace among valid lines | `-failed` |
| `defects.txt` | All three realistic defects in one file | `-failed` |
| `execution-defects.txt` | The two execution-time defects with no syntax error in the way | `-failed` |

The defects are the kind that actually happen - a brace missed while editing, a
field name typed slightly wrong, an identifier copied from the wrong row - not
contrived syntax garbage. Each one fails differently and is reported
differently, which is the point.

`defects.txt` and `execution-defects.txt` are deliberately separate. Validation
runs over the whole file before anything executes, so a syntax error anywhere
means the execution-time defects are never reached on that run. Fixing the
brace and resubmitting is what surfaces them - which is exactly the
correct-and-resubmit loop the reports are written for.

Running `all-good.txt` repeatedly changes the data it queries: the Reston
listings become `pending`, so the second run's `updateMany` matches nothing and
the file then fails. That is the intended behaviour, not a flaw - it is the
same no-match defect, and it is why the reset exists:

```bash
# variable form
MONGO_URI=$MONGO_URI python3 seed/seed.py

# expanded
MONGO_URI=mongodb://localhost:27017 python3 seed/seed.py
```
