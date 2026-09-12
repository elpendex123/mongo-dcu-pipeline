# Phase 4 - Local vertical slice

**What this phase built:** the nine application modules, the RDS schema, the
100 seed documents, the sample files and the Compose stack - ending with a file
routed end to end.

MongoDB and MySQL are containers standing in for DocumentDB and RDS. **S3 is
real.**

## Variables used in this guide

Repeated here so the page stands alone; the full list, including the values AWS
generates, is in [README.md](README.md).

```bash
export PROJECT_ROOT=~/Documents/PROJECTS/mongo-dcu-pipeline
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

| Variable | Example value | Where it comes from |
|---|---|---|
| `PROJECT_ROOT` | `~/Documents/PROJECTS/mongo-dcu-pipeline` | Wherever you cloned the repository |
| `ACCOUNT_ID` | `950639281723` | 12 digits, fixed per AWS account. From `aws sts get-caller-identity` |
| `KEY` | `one-bad-line.txt.4f1c8a90-3b2e-4d17-9c55-1e0a7f6b2d84.report.log` | **Generated per run.** Source filename + the run's UUID. Section 5 sets it by listing the bucket rather than typing it - the UUID is different on every run and cannot be predicted |

Inside the app container, MongoDB and MySQL are reached by service name -
`mongodb://mongo:27017` and `mysql:3306` - not `localhost`. From your own shell
they are `localhost:27017` and `localhost:3306`, because Compose publishes the
ports. Both forms appear below; the difference is which side of the container
boundary the command runs on.

Every command below is given in a variable form and again fully expanded.

## 1. Start the stack

```bash
# variable form
cd $PROJECT_ROOT
cp .env.example .env          # first time only
docker compose up -d --build
docker compose ps

# expanded
cd ~/Documents/PROJECTS/mongo-dcu-pipeline
cp .env.example .env
docker compose up -d --build
docker compose ps
```

Expect `app`, `mongo` and `mysql` running, the latter two healthy.

If the host user is not uid 1000, set `APP_UID` and `APP_GID` in `.env` to
match `id -u` and `id -g` and rebuild - see issue 5 in [ISSUES.md](../ISSUES.md).

## 2. Startup proves its own dependencies

```bash
docker compose logs app --no-log-prefix | head -20
```

Expect, in order: the metrics endpoint listening, then the document database,
then the run history database, then the polling loop starting. All five buckets
are checked with `head_bucket` before any of that. A wrong endpoint or a missing
permission fails here, in the first seconds, rather than when a file arrives.

There should be **no** `could not open the log directory` line. Confirm the
file Splunk will monitor is actually being written:

```bash
docker compose exec app tail -3 /var/log/mongo-dcu/app.log
```

## 3. Seed the data

```bash
docker compose run --rm seed
```

Expect `dropping mongo_dcu.properties`, `created 5 indexes`, `inserted 100
documents`. The collection is dropped rather than emptied, so indexes reset too.

## 4. The success path

```bash
# variable form
aws s3 cp samples/all-good.txt s3://mongo-dcu-pipeline-dev-input-$ACCOUNT_ID/
docker compose logs -f app

# expanded
aws s3 cp samples/all-good.txt s3://mongo-dcu-pipeline-dev-input-950639281723/
docker compose logs -f app
```

Within one polling cycle (20s) expect a line per query and then:

```
msg="run finished" status=success destination_bucket=...-dev-successful-...
  total_lines=9 success=9 fail_syntax=0 fail_execution=0 duration_ms=64
```

Every log line carries `env`, `component` and `run_id`, in the pipe-delimited
`key=value` form Splunk extracts with no configuration.

```bash
./scripts/dev-s3-status.sh
```

Expect the file in `-successful`, one report in each of the two report buckets,
and `-input` and `-failed` empty. **Reports never go to `-failed`** - that
bucket stays a clean queue of files needing reprocessing.

## 5. The syntax failure path

```bash
aws s3 cp samples/one-bad-line.txt s3://mongo-dcu-pipeline-dev-input-$ACCOUNT_ID/
```

Expect `status=failed`, the file in `-failed`, and **nothing executed** -
validation runs over the whole file first, so a syntax error anywhere means no
query in the file runs.

Read the report as its intended audience:

```bash
# variable form
KEY=$(aws s3 ls s3://mongo-dcu-pipeline-dev-reports-log-$ACCOUNT_ID/ | grep one-bad-line | awk '{print $4}')
aws s3 cp s3://mongo-dcu-pipeline-dev-reports-log-$ACCOUNT_ID/$KEY - | cat

# expanded
aws s3 ls s3://mongo-dcu-pipeline-dev-reports-log-950639281723/
aws s3 cp s3://mongo-dcu-pipeline-dev-reports-log-950639281723/<the key> - | cat
```

Expect a caret under the offending character:

```
  line 7 - fail_syntax (rejected before reaching the database)
    db.properties.find({ "bedrooms": { "$gte": 4 })
                                                  ^
    '{' opened at col 20 is closed by ')'
    failed at the 'delimiters' check
```

## 6. Both defects in one file, and the two kinds of failure

```bash
aws s3 cp samples/defects.txt s3://mongo-dcu-pipeline-dev-input-$ACCOUNT_ID/
```

Expect `fail_syntax=1` and, in the report, the two valid lines marked `--`
(`not_run`) - valid, but never attempted because another line failed. See issue
7 in [ISSUES.md](../ISSUES.md): a report must account for every line, or a
reader cannot tell an omission from an absence.

Then the execution-time defects with nothing blocking them:

```bash
aws s3 cp samples/execution-defects.txt s3://mongo-dcu-pipeline-dev-input-$ACCOUNT_ID/
```

Expect `success=2 fail_execution=2`, and these two messages:

```
filter matched no documents, so nothing was updated - check the field names and values in the filter
filter matched no documents, so nothing was deleted - check the field names and values in the filter
```

**This is the point of the whole pipeline.** Both queries are valid, the driver
raised nothing, and both changed nothing - a typo'd field name and an identifier
that does not exist. Reported as successes they would be indistinguishable from
work done.

## 7. Run history

```bash
docker compose exec mysql mysql -u mongo_dcu -pdevpassword mongo_dcu -e "
SELECT file_name, status, total_lines, success_count, syntax_fail_count, execution_fail_count, duration_ms
  FROM runs ORDER BY started_at;
SELECT status, COUNT(*) FROM run_lines GROUP BY status;
SELECT error_stage, COUNT(*) FROM run_lines WHERE error_stage IS NOT NULL GROUP BY error_stage;"
```

Expect one row per file, per-line rows including `not_run`, and `error_stage`
populated - which is what makes "how often does a missing brace reach QA" a
question answerable in SQL.

## 8. Metrics

```bash
curl -s localhost:9090/metrics | grep -E '^(files_processed_total|lines_failed_total|last_run_timestamp|poll_cycles_total)'
```

Expect `files_processed_total` split by status and `lines_failed_total` split
by `reason="syntax"` and `reason="execution"` - separated because "syntax
failures went up" points at whoever is writing the files, while "execution
failures went up" points at the database.

## 9. Graceful shutdown

```bash
docker compose stop app
docker compose logs app --no-log-prefix | tail -4
docker inspect mongo-dcu-app --format '{{.State.ExitCode}}'
```

Expect `shutdown signal received, will stop after the current file`, then a
clean stop, and **exit code 0** - the signal was handled, not killed. 143 would
mean the process was terminated rather than shutting itself down, which in
Kubernetes would risk abandoning a file mid-run.

## A note on repeat runs

`all-good.txt` is deliberately not idempotent. Its `updateMany` sets the Reston
listings to `pending`, so a second run matches nothing and the file fails on the
no-match rule. That is the same defect working as designed. Reset with:

```bash
docker compose run --rm seed
```

## Tear down

```bash
docker compose down        # keeps the seeded data in named volumes
docker compose down -v     # also discards MongoDB, MySQL and the log volume
```

The AWS side costs a fraction of a cent per month and is normally left alone.

## Pass criteria

- [ ] Three services up; startup log shows S3, MongoDB and MySQL all proved
- [ ] `app.log` is being written inside the container
- [ ] Seeder loads 100 documents and 5 indexes
- [ ] `all-good.txt` lands in `-successful` with reports in both report buckets
- [ ] `one-bad-line.txt` lands in `-failed` with nothing executed and a caret in the report
- [ ] `defects.txt` shows the valid lines as `not_run`
- [ ] `execution-defects.txt` catches both no-match writes
- [ ] MySQL holds the runs and per-line rows
- [ ] Metrics split failures by reason
- [ ] `docker compose stop app` exits 0
