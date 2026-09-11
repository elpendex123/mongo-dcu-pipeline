# Phase 1 - Terraform remote state

**What this phase built:** the directory tree, and `terraform/bootstrap/` - the
stack that creates the S3 bucket every other stack uses as its backend.

## 1. The tree matches the design

```bash
# variable form
cd $PROJECT_ROOT && find . -type d -not -path './.git/*' -not -path './.terraform*' -not -path './.venv*' | sort

# expanded
cd ~/Documents/PROJECTS/mongo-dcu-pipeline && find . -type d -not -path './.git/*' -not -path './.terraform*' -not -path './.venv*' | sort
```

Expect `app/`, `terraform/{bootstrap,modules,environments}`, `ansible/`,
`helm/`, `jenkins/`, `scripts/`, `sql/`, `seed/`, `samples/`, `docs/`.

## 2. The state bucket exists, with every protection on

```bash
# variable form
export STATE_BUCKET=mongo-dcu-pipeline-tfstate-$ACCOUNT_ID
aws s3api get-bucket-versioning --bucket $STATE_BUCKET
aws s3api get-bucket-encryption --bucket $STATE_BUCKET --query 'ServerSideEncryptionConfiguration.Rules'
aws s3api get-public-access-block --bucket $STATE_BUCKET --query 'PublicAccessBlockConfiguration'
aws s3api get-bucket-lifecycle-configuration --bucket $STATE_BUCKET --query 'Rules[].ID'

# expanded
aws s3api get-bucket-versioning --bucket mongo-dcu-pipeline-tfstate-950639281723
aws s3api get-bucket-encryption --bucket mongo-dcu-pipeline-tfstate-950639281723 --query 'ServerSideEncryptionConfiguration.Rules'
aws s3api get-public-access-block --bucket mongo-dcu-pipeline-tfstate-950639281723 --query 'PublicAccessBlockConfiguration'
aws s3api get-bucket-lifecycle-configuration --bucket mongo-dcu-pipeline-tfstate-950639281723 --query 'Rules[].ID'
```

Expect, in order: `"Status": "Enabled"`; `AES256` with `BucketKeyEnabled`;
all four public access settings `true`; a rule named
`expire-noncurrent-state-versions`.

## 3. The code and the live bucket agree

The real check. A plan reporting no changes proves the configuration describes
what actually exists.

```bash
# variable form
terraform -chdir=$PROJECT_ROOT/terraform/bootstrap plan

# expanded
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/bootstrap plan
```

Expect `No changes. Your infrastructure matches the configuration.`

## 4. Tag-based discovery works

Everything in Phase 6's `status.sh` and `nuke.sh` depends on this query
returning every project resource. It is worth confirming it works while there
is only one resource to find.

```bash
# variable form
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=project,Values=mongo-dcu-pipeline \
  --query 'ResourceTagMappingList[].ResourceARN' --output table

# expanded - same command, the project slug is literal
```

Expect the state bucket's ARN and, once Phase 2 is up, the five dev buckets.

```bash
aws s3api get-bucket-tagging --bucket $STATE_BUCKET --query 'TagSet'
```

Expect `project=mongo-dcu-pipeline`, `environment=shared`,
`managed_by=terraform`, plus `Name`. The first three come from the provider's
`default_tags`, so no individual resource has to remember them.

## 5. State keys are separated per environment

```bash
aws s3 ls s3://$STATE_BUCKET --recursive
```

Expect `dev/terraform.tfstate` once Phase 2 has been applied. Each environment
gets its own key so `dev` can be destroyed without touching `qa` or `prod`.

## Note on the bootstrap stack's own state

It is local and not in version control - it cannot store state in the bucket it
creates. If it is lost, the bucket still works; only Terraform's ability to
manage that one bucket is lost, and it can be recovered:

```bash
terraform -chdir=$PROJECT_ROOT/terraform/bootstrap import \
  aws_s3_bucket.tfstate mongo-dcu-pipeline-tfstate-950639281723
```

## Pass criteria

- [ ] Directory tree matches the design
- [ ] Versioning, SSE-S3, public access block and lifecycle rule all confirmed
- [ ] `terraform plan` reports no changes
- [ ] The tag query returns the bucket
- [ ] `dev/terraform.tfstate` is present in the bucket
