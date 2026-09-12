# Validation guides

One guide per completed phase. Each is a set of commands with the output to
expect, so that what was built can be checked independently rather than taken
on trust. Every command is given in both a variable form and a fully expanded
form, so it can be practised by hand as well as pasted.

| Phase | Guide | Proves |
|---|---|---|
| 0 | [Repository](PHASE-00-repository.md) | Git, the public repository, and what is deliberately not in it |
| 1 | [Terraform state](PHASE-01-terraform-state.md) | The state bucket and the tag-based discovery everything else depends on |
| 2 | [Dev S3](PHASE-02-dev-s3.md) | The reusable module, the dev stack, and all four scripts |
| 3 | [Parser and validator](PHASE-03-parser-validator.md) | All five validation checks, by test suite and by hand |
| 4 | [Vertical slice](PHASE-04-vertical-slice.md) | A file routed end to end, with reports, history and metrics |
| 5 | [Container registry](PHASE-05-ecr.md) | The shared stack, the image in ECR, and the trap in the tag query |
| 6 | [AWS foundations](PHASE-06-aws-foundations.md) | The data tier, qa, and the three scripts that stop the account billing |

## Variables used in these guides

Set these once per shell. Every command in every guide is given in a variable
form and again fully expanded, so either can be pasted.

```bash
export PROJECT_ROOT=~/Documents/PROJECTS/mongo-dcu-pipeline
export PROJECT=mongo-dcu-pipeline
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cd $PROJECT_ROOT
```

| Variable | Example value | Where it comes from |
|---|---|---|
| `PROJECT_ROOT` | `~/Documents/PROJECTS/mongo-dcu-pipeline` | Wherever you cloned the repository. Yours may differ |
| `PROJECT` | `mongo-dcu-pipeline` | Fixed. The project slug, and the value of the `project` tag on every resource |
| `AWS_REGION` | `us-east-1` | Fixed for this project |
| `ACCOUNT_ID` | `950639281723` | 12 digits, fixed per AWS account. From `aws sts get-caller-identity` |
| `STATE_BUCKET` | `mongo-dcu-pipeline-tfstate-950639281723` | Derived: `$PROJECT-tfstate-$ACCOUNT_ID` |
| `S3_INPUT_BUCKET` | `mongo-dcu-pipeline-dev-input-950639281723` | Derived: `$PROJECT-dev-input-$ACCOUNT_ID`. Also printed by the dev stack's `env_file_lines` output |

Every name in this project is derived from the slug and the account ID, so
nothing above has to be looked up in the console.

### Values that are generated, not chosen

These cannot be set in advance. Each guide says where to read the real one; the
examples below are only there to show the shape.

| Value | Example | How it is produced |
|---|---|---|
| `REPO_URI` | `950639281723.dkr.ecr.us-east-1.amazonaws.com/mongo-dcu-pipeline-app` | Assembled by ECR. Read with `aws ecr describe-repositories` |
| `TAG` | `142a514` | `git rev-parse --short HEAD`. Seven hex characters, different at every commit; `-dirty` appended on an unclean tree |
| `run_id` | `4f1c8a90-3b2e-4d17-9c55-1e0a7f6b2d84` | A UUID the application generates per run. Appears in log lines, report filenames and the `runs` table |
| Report key | `one-bad-line.txt.4f1c8a90-….report.log` | Source filename + `run_id`, so the two report formats correlate. Never the same twice |
| DocumentDB endpoint | `mongo-dcu-pipeline-docdb-qa.cluster-cxyz123abc45.us-east-1.docdb.amazonaws.com` | AWS assigns the `cluster-` portion at creation. From a Terraform output, into Secrets Manager (Phase 6) |
| RDS endpoint | `mongo-dcu-pipeline-rds.cxyz123abc45.us-east-1.rds.amazonaws.com` | Same shape, same story (Phase 6) |
| Secret ARN | `arn:aws:secretsmanager:us-east-1:950639281723:secret:mongo-dcu-pipeline/qa/docdb-AbCdEf` | Secrets Manager appends six random characters, so a deleted and recreated secret never collides with the old ARN (Phase 6) |
| ECR login password | a ~2 KB token | `aws ecr get-login-password`, valid 12 hours, different every call. Piped into `docker login`, never stored |
| `promotion_token` | `9f2c1d7a4b8e6350` | Generated on a fully successful QA run, single use, 24-hour expiry (Phase 9) |

A variable that appears inside a `for` loop in a snippet - `$name`, `$bucket`,
`$KEY` - is set by the line above it and is not yours to set.

### Required tooling

`terraform` >= 1.10, `aws` v2, `jq`, `docker` with Compose v2, `git`, `gh`.
Python 3.12 or newer for the local virtual environment.

## Five-minute check

Enough to confirm nothing has regressed, without reading any single guide.

```bash
cd $PROJECT_ROOT

git status --short                                  # expect: empty
.venv/bin/python -m pytest                          # expect: 110 passed
terraform -chdir=terraform/bootstrap plan           # expect: No changes
terraform -chdir=terraform/environments/dev plan    # expect: No changes
terraform -chdir=terraform/environments/shared plan # expect: No changes
./scripts/dev-s3-status.sh                          # expect: present: 5  absent: 0
aws ecr list-images --repository-name mongo-dcu-pipeline-app --region us-east-1
```

If the local stack is running, add:

```bash
docker compose ps                                   # expect: 3 services up
curl -s localhost:9090/metrics | head -1            # expect: a metric line
```

## What is deliberately not automated

These guides are read and run by a person. A script that checked all of it
would be a seventh thing to maintain, and the point of the exercise is partly
to practise the commands by hand - `status.sh` in Phase 6 is where the
automated version of the AWS half arrives.
