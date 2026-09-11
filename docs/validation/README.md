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

## Shared setup

```bash
# variable form
export PROJECT_ROOT=$HOME/Documents/PROJECTS/mongo-dcu-pipeline
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cd $PROJECT_ROOT

# expanded
export PROJECT_ROOT=~/Documents/PROJECTS/mongo-dcu-pipeline
export AWS_REGION=us-east-1
export ACCOUNT_ID=950639281723
cd ~/Documents/PROJECTS/mongo-dcu-pipeline
```

Required tooling: `terraform` >= 1.10, `aws` v2, `jq`, `docker` with Compose v2,
`git`, `gh`. Python 3.12 or newer for the local virtual environment.

## Five-minute check

Enough to confirm nothing has regressed, without reading any single guide.

```bash
cd $PROJECT_ROOT

git status --short                                  # expect: empty
.venv/bin/python -m pytest                          # expect: 110 passed
terraform -chdir=terraform/bootstrap plan           # expect: No changes
terraform -chdir=terraform/environments/dev plan    # expect: No changes
./scripts/dev-s3-status.sh                          # expect: present: 5  absent: 0
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
