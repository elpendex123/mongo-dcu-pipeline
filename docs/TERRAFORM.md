# Terraform

## Variables used on this page

```bash
export PROJECT_ROOT=~/Documents/PROJECTS/mongo-dcu-pipeline
export PROJECT=mongo-dcu-pipeline
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export STATE_BUCKET=$PROJECT-tfstate-$ACCOUNT_ID
```

| Variable | Example value | Where it comes from |
|---|---|---|
| `PROJECT_ROOT` | `~/Documents/PROJECTS/mongo-dcu-pipeline` | Wherever you cloned the repository |
| `PROJECT` | `mongo-dcu-pipeline` | Fixed. The project slug, and the value of the `project` tag |
| `AWS_REGION` | `us-east-1` | Fixed for this project |
| `ACCOUNT_ID` | `950639281723` | 12 digits, fixed per AWS account. From `aws sts get-caller-identity` |
| `STATE_BUCKET` | `mongo-dcu-pipeline-tfstate-950639281723` | Derived, not invented: slug + `-tfstate-` + account ID. The suffix exists because S3 bucket names are globally unique across every AWS account |

Terraform itself never reads these. They are for the commands on this page; the
stacks derive the same values from `data.aws_caller_identity.current`, which is
why nothing breaks in a different account.

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

## The S3 module

`terraform/modules/s3/` produces one environment's full set of buckets. It
takes the project slug, the environment, the account ID and a list of bucket
roles, and returns maps of role to name and role to ARN.

```hcl
module "buckets" {
  source = "../../modules/s3"

  project       = "mongo-dcu-pipeline"
  environment   = "dev"
  account_id    = data.aws_caller_identity.current.account_id
  force_destroy = true
}
```

Every bucket it creates gets versioning, SSE-S3 encryption, all four public
access blocks, and a lifecycle rule expiring superseded versions after 30 days.

Resources are keyed by role (`for_each` over a map) rather than by list index,
so adding a sixth bucket later does not shift the others' addresses in state
and force them to be recreated.

The outputs are maps rather than five separate values because the consumers
want them that way: the application reads bucket names from environment
variables, and the IAM module scopes the pod's policy to exactly this
environment's ARNs.

| Environment | `force_destroy` | Why |
|---|---|---|
| `dev` | `true` | Created and destroyed constantly, holds only throwaway test files |
| `qa` / `prod` | `false` | A destroy should fail loudly on a non-empty bucket rather than take real run history with it |

## The dev environment

`terraform/environments/dev/` is S3 only. The application, MongoDB and MySQL
all run locally under Docker Compose, but the buckets are real - file pickup,
the copy-then-delete move between buckets and report upload are exercised
against actual S3 from the first local run. Storage for a handful of small text
files is a fraction of a cent per month, so there is nothing to gain from
faking it.

Its `env_file_lines` output prints the bucket names in the exact form the local
environment file wants, so nothing has to be transcribed by hand:

```bash
# variable form
terraform -chdir=$PROJECT_ROOT/terraform/environments/dev output -raw env_file_lines

# expanded
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/dev \
  output -raw env_file_lines
```

## The shared stack

`terraform/environments/shared/` holds what belongs to neither qa nor prod: the
ECR repository `mongo-dcu-pipeline-app` and the analytics exports bucket. Its
own state key, and the tag `environment=shared`.

The reason is lifecycle, not tidiness. qa and prod are created and destroyed
repeatedly, and both run the same image. If the registry lived in the qa stack,
`terraform destroy` on qa would delete the image prod runs. Separate state
means an environment destroy cannot reach these resources at all - not because
a rule forbids it, but because they are not in that environment's state.

```bash
# variable form
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared init
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared apply

# expanded
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/shared apply
```

The analytics bucket is written out as plain resources rather than built from
`modules/s3`. That module produces a set of five buckets named
`{project}-{environment}-{role}-{account}`; this is a single bucket whose name
carries no environment component at all. Putting it through the module would
mean a name override and a relaxed environment validation for the sake of one
bucket - more indirection than four protection resources written directly.

Registry settings and the image tagging scheme are in [ECR.md](ECR.md).

### The state bucket is tagged too

`terraform/bootstrap` tags the state bucket `project=mongo-dcu-pipeline,
environment=shared`, exactly like everything else, so the tag query returns
three ARNs for `environment=shared` rather than two.

That is right for discovery and dangerous for deletion. `nuke.sh` (Phase 6) is
defined as force-delete everything carrying the project tag; run naively it
would delete the state for every environment and the registry every environment
pulls from - leaving the resources themselves running, billing, with nothing
left that knows they exist. The state bucket and the ECR repository therefore
go on an explicit exclusion list in that script. A discovery query and a
deletion query are not the same query.

## The data tier

`terraform/environments/shared-data/` holds one VPC and the shared MySQL
instance. A third lifecycle, between the other two:

| Stack | Holds | Lifecycle | Cost |
|---|---|---|---|
| `shared` | ECR repository, analytics bucket | Permanent | A few cents a month |
| `shared-data` | Data tier VPC, RDS MySQL | Session-scoped | ~$0.02/hr |
| `qa` / `prod` | VPC, endpoints, DocumentDB, buckets, secrets, IAM | Session-scoped, destroyed independently | ~$0.14/hr each |

Not in `qa`, because qa is destroyed at the end of every session and that
destroy would take prod's run history and its promotion tokens with it. Not in
`shared` either, because an RDS instance left up the way the registry is left
up is $12 a month. Each stack is now either permanent and free, or
session-scoped and billable, and none is both.

**Apply order: `shared-data` before `qa`.** The qa stack reads the data tier's
outputs through a `terraform_remote_state` data source to build its peering
connection, and fails at plan time if that stack has never been applied.

### Who owns the peering connection

qa does, not the data tier - including the return route that lives in the data
tier's route table. The lifecycle then reads correctly: the peering exists
because qa exists, and destroying qa takes it away. One stack writing a single
route into another stack's route table is the price, and it is cheaper than the
alternative, which is a connection that outlives the VPC it connects.

Two details that produce an *active* peering connection and a hung connection:

- **`allow_remote_vpc_dns_resolution` on both sides.** Without it a pod
  resolving the RDS hostname gets the instance's public address, and the qa VPC
  has no internet gateway.
- **The return route goes in the data tier's PUBLIC route table**, because that
  is where the RDS instance's subnets are.

## The environment modules

| Module | Produces | Worth knowing |
|---|---|---|
| `vpc/` | VPC, subnets across 2 AZs, route tables, optionally an IGW | Private by default. `create_public_subnets` is true only for the data tier |
| `vpc-endpoints/` | S3 gateway endpoint plus six interface endpoints | Interface endpoints bill **per AZ**. Placed in one AZ deliberately: $0.06/hr instead of $0.12 |
| `documentdb/` | Cluster, one instance, subnet group, parameter group, security group | TLS enforced; the URI needs `replicaSet=rs0` and `retryWrites=false` |
| `rds/` | MySQL instance, subnet group, security group | Detects your public address at apply time for the admin rule |
| `secrets-manager/` | One secret per entry, from a map | `recovery_window_days = 0`, or a destroyed environment leaves secrets billing and their names unusable |
| `iam/` | The application policy, and the IRSA role once a cluster exists | The role is skipped while `oidc_provider_arn` is empty - it cannot trust a provider that does not exist yet |

### Why the endpoint list has six entries

`CLAUDE.md` §9 named four: S3, ECR, Secrets Manager, CloudWatch. Building it
produced two more:

- **`sts`** - IRSA obtains credentials by calling `AssumeRoleWithWebIdentity`.
  Without a route to STS, a pod with a perfectly correct role gets no
  credentials at all.
- **`ec2`** - the VPC CNI calls the EC2 API to attach addresses to pods. Added
  now rather than in Phase 7, so the cluster does not come up onto a wall.

And `ecr.api` and `ecr.dkr` are two endpoints, not one: authentication and
metadata go to one service, layer downloads to another. Layers themselves come
from S3, so the free S3 gateway endpoint is required for a pull to work at all.

## Dev S3 scripts

Four thin wrappers in `scripts/`, deliberately not Jenkins jobs - dev is
low-stakes enough to drive directly.

| Script | Does |
|---|---|
| `dev-s3-create.sh` | `terraform apply` against `environments/dev`, then prints the bucket names and the environment file lines |
| `dev-s3-destroy.sh` | `terraform destroy`, the ordinary teardown path, leaves state consistent |
| `dev-s3-status.sh` | Read only: existence, object count, size, and whether versioning, encryption and public access blocking are actually on |
| `dev-s3-nuke.sh` | Force-deletes the buckets through the AWS API with no reference to Terraform state |

All four accept `--yes` to skip the confirmation prompt, and the destructive
two refuse to run unattended without it rather than hanging on a prompt no one
will answer in a Jenkins job.

```bash
# variable form
$PROJECT_ROOT/scripts/dev-s3-create.sh
$PROJECT_ROOT/scripts/dev-s3-status.sh
$PROJECT_ROOT/scripts/dev-s3-destroy.sh --yes

# expanded
~/Documents/PROJECTS/mongo-dcu-pipeline/scripts/dev-s3-create.sh
~/Documents/PROJECTS/mongo-dcu-pipeline/scripts/dev-s3-status.sh
~/Documents/PROJECTS/mongo-dcu-pipeline/scripts/dev-s3-destroy.sh --yes
```

### Why nuke exists alongside destroy

`terraform destroy` is the right tool when state is intact. `dev-s3-nuke.sh` is
for when it is not - a partial apply, a lost state file, a resource deleted by
hand outside Terraform. It finds the buckets by name and deletes them directly.

Emptying a versioned bucket is the part worth knowing: `aws s3 rm --recursive`
removes only current versions, leaving every previous version and every delete
marker behind, and a bucket that still contains those cannot be deleted. The
script pages through `list-object-versions` and deletes versions and delete
markers together.

After a nuke, dev's Terraform state still lists buckets that no longer exist.
Reconcile by applying again:

```bash
# variable form
terraform -chdir=$PROJECT_ROOT/terraform/environments/dev apply

# expanded
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/dev apply
```

### Prerequisites

`terraform`, `aws` (v2) and `jq`. Each script checks for what it needs up front
and names anything missing, rather than failing midway with an opaque error.
