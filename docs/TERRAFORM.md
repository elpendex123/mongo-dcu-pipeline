# Terraform

## Layout

```
terraform/
  bootstrap/                 # run once, local state - creates the state bucket itself
  modules/
    s3/                      # reusable bucket set, used by dev, qa and prod
    vpc/
    vpc-endpoints/
    eks/
    documentdb/
    rds/
    iam/                     # includes the IRSA role definitions
    secrets-manager/
  environments/
    dev/                     # S3 buckets only
    qa/                      # full stack
    prod/                    # same shape as qa, separate state
    shared/                  # ECR repository and the analytics bucket
```

Each environment is a separate root module with its own state key, so `dev` can
be created and destroyed without touching `qa`, and `qa` without touching
`prod`. `shared/` holds what belongs to neither environment, so destroying an
environment never takes the container registry with it.

## State backend

| Setting | Value |
|---|---|
| Bucket | `mongo-dcu-pipeline-tfstate-950639281723` |
| Region | `us-east-1` |
| Keys | `dev/terraform.tfstate`, `qa/terraform.tfstate`, `prod/terraform.tfstate`, `shared/terraform.tfstate` |
| Encryption | SSE-S3 (AES256), bucket keys enabled |
| Versioning | Enabled, superseded versions expire after 90 days |
| Locking | S3 native (`use_lockfile = true`) |

Locking uses S3 directly rather than a DynamoDB table. Terraform has supported
this since 1.10, and it removes a whole service from the account - one less
thing to provision, pay for, and remember to delete.

The backend block every environment uses:

```hcl
terraform {
  backend "s3" {
    bucket       = "mongo-dcu-pipeline-tfstate-950639281723"
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

## The bootstrap stack

`terraform/bootstrap/` creates the state bucket. It cannot store its own state
in the bucket it creates, so its state is local - which is exactly why it is
kept separate and as small as possible. It is run once, at the start of the
project, and then left alone.

```bash
# variable form
cd $PROJECT_ROOT/terraform/bootstrap
terraform init
terraform apply

# expanded
cd ~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/bootstrap
terraform init
terraform apply
```

Its local state file is not in version control. If it is lost, the bucket is
still there and still works - only the ability to manage that one bucket
through Terraform is lost, and it can be recovered with `terraform import`:

```bash
# variable form
terraform import aws_s3_bucket.tfstate $STATE_BUCKET

# expanded
terraform import aws_s3_bucket.tfstate mongo-dcu-pipeline-tfstate-950639281723
```

## Tagging

The AWS provider in every stack sets default tags, so no individual resource
has to remember them:

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project     = "mongo-dcu-pipeline"
      environment = "dev"          # or qa, prod, shared
      managed_by  = "terraform"
    }
  }
}
```

This matters beyond tidiness: `scripts/status.sh` and `scripts/nuke.sh` find
resources by tag rather than by enumerating each service's API, so an untagged
resource is a resource that survives teardown unnoticed and keeps billing.

Check what the tag query currently returns:

```bash
# variable form
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=project,Values=$PROJECT \
  --query 'ResourceTagMappingList[].ResourceARN' --output table

# expanded
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=project,Values=mongo-dcu-pipeline \
  --query 'ResourceTagMappingList[].ResourceARN' --output table
```

## Conventions

- `required_version = ">= 1.10.0"` - S3 native locking is the floor.
- AWS provider pinned with `~> 6.0`; `.terraform.lock.hcl` is committed so
  every machine resolves the same provider build.
- `terraform fmt -recursive` and `terraform validate` before every commit.
- Names are derived, not hardcoded: the account ID comes from
  `data.aws_caller_identity.current`, so nothing breaks in another account.
