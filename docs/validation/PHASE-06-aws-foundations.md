# Phase 6 - AWS foundations and the cost guard

**What this phase built:** six Terraform modules, the data tier, the qa
environment, and the three scripts that keep the account from quietly billing -
`status.sh`, `nuke.sh` and `teardown.sh`.

**Cost: this is the first phase that spends money.** qa plus the data tier is
about **$0.154/hr** with no cluster yet. Run `status.sh` before you stop for the
day, and `teardown.sh` when you do.

## Variables used in this guide

Repeated here so the page stands alone; the full list, including the values AWS
generates, is in [README.md](README.md).

```bash
export PROJECT_ROOT=~/Documents/PROJECTS/mongo-dcu-pipeline
export PROJECT=mongo-dcu-pipeline
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

| Variable | Example value | Where it comes from |
|---|---|---|
| `PROJECT_ROOT` | `~/Documents/PROJECTS/mongo-dcu-pipeline` | Wherever you cloned the repository |
| `PROJECT` | `mongo-dcu-pipeline` | Fixed |
| `AWS_REGION` | `us-east-1` | Fixed |
| `ACCOUNT_ID` | `950639281723` | From `aws sts get-caller-identity` |

**Generated, not chosen** - every one of these is read from a Terraform output,
never typed:

| Value | Example shape | How it is produced |
|---|---|---|
| DocumentDB endpoint | `mongo-dcu-pipeline-docdb-qa.cluster-cypgou004zcv.us-east-1.docdb.amazonaws.com` | AWS assigns the `cluster-` portion at creation |
| RDS endpoint | `mongo-dcu-pipeline-rds.cypgou004zcv.us-east-1.rds.amazonaws.com` | Same |
| Secret ARN | `…:secret:mongo-dcu-pipeline/qa/docdb-tdCX5y` | Secrets Manager appends six random characters |
| VPC / subnet / peering ids | `vpc-0e5abaf8e470e2c63`, `pcx-047d9300e88d669de` | Assigned at creation |
| Master passwords | 32 characters | `random_password`, straight into Secrets Manager |
| `admin_cidr` | `108.45.138.62/32` | Your public address, detected at apply time |

## Apply order matters

The qa stack reads the data tier's outputs to build its peering connection, so
the data tier goes first. Applying qa against a data tier that has never been
applied fails at plan time.

```bash
# variable form
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared-data apply
terraform -chdir=$PROJECT_ROOT/terraform/environments/qa apply

# expanded
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/shared-data apply
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/qa apply
```

22 resources then 56. The DocumentDB cluster is the slow part, six to ten
minutes on its own.

## 1. status.sh tells you what it costs

```bash
cd $PROJECT_ROOT && ./scripts/status.sh
```

The section that matters is the last one:

```
cost
  billable resources running: 8
  approximate cost:  $0.154/hr   $3.70/day if left up   $111/month if left up

  !! 8 billable resource(s) are up - run scripts/teardown at the end of the session
```

Eight is one DocumentDB instance, six interface endpoints, and one RDS
instance. **Count them against the report.** A total that does not match what
you can count is a bug in the report, not a rounding detail - that is how
issue 10 was found.

The report also proves things that are easy to assume and worth seeing:

- every interface endpoint says **`1 AZ`**. Interface endpoints bill per
  availability zone, so a two-AZ placement would be $0.12/hr for this VPC
  rather than $0.06 - more than the DocumentDB instance
- the S3 endpoint says **`Gateway  free`**, because it is a route, not an ENI
- the peering connection says **`active`**
- there is no NAT gateway section, because there is no NAT gateway. If one ever
  appears, `status.sh` says so loudly

## 2. The private VPC really has no way out

```bash
# variable form
aws ec2 describe-route-tables --region $AWS_REGION \
  --filters "Name=vpc-id,Values=$(terraform -chdir=$PROJECT_ROOT/terraform/environments/qa output -raw vpc_id)" \
  --query 'RouteTables[].Routes[].{dest:DestinationCidrBlock,gw:GatewayId,pcx:VpcPeeringConnectionId}' --output table

# expanded
aws ec2 describe-route-tables --region us-east-1 \
  --filters "Name=vpc-id,Values=vpc-0e5abaf8e470e2c63" \
  --query 'RouteTables[].Routes[].{dest:DestinationCidrBlock,gw:GatewayId,pcx:VpcPeeringConnectionId}' --output table
```

Expect exactly two kinds of route: `10.10.0.0/16` local, and `10.0.0.0/16` via
the peering connection. **No `0.0.0.0/0` anywhere.** Everything the application
reaches - S3, ECR, Secrets Manager, CloudWatch, STS - it reaches through the
endpoints.

## 3. RDS is reachable from here, and only from here

```bash
# variable form
export RDS_HOST=$(terraform -chdir=$PROJECT_ROOT/terraform/environments/shared-data output -raw rds_address)
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$RDS_HOST/3306" && echo reachable

# expanded
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/mongo-dcu-pipeline-rds.cypgou004zcv.us-east-1.rds.amazonaws.com/3306' && echo reachable
```

Reachable from your machine because the security group names your address:

```bash
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared-data output admin_cidr
curl -s https://checkip.amazonaws.com
```

Those two should agree. When they stop agreeing - and on a home connection they
eventually will - that is why a promotion job cannot connect.

## 4. The secrets exist and hold what they should

```bash
# variable form
aws secretsmanager get-secret-value --secret-id $PROJECT/qa/docdb \
  --region $AWS_REGION --query SecretString --output text | jq 'keys'

# expanded
aws secretsmanager get-secret-value --secret-id mongo-dcu-pipeline/qa/docdb \
  --region us-east-1 --query SecretString --output text | jq 'keys'
```

Expect `["host","password","port","uri","username"]`. To see the URI's shape
without printing the password:

```bash
aws secretsmanager get-secret-value --secret-id mongo-dcu-pipeline/qa/docdb \
  --region us-east-1 --query SecretString --output text \
  | jq -r .uri | sed 's|//[^@]*@|//<credentials>@|'
```

It should carry `tls=true`, `tlsCAFile=/etc/ssl/certs/global-bundle.pem`,
`replicaSet=rs0` and `retryWrites=false`. All four matter - `docs/DOCUMENTDB.md`
explains what breaks without each.

Three secrets, not four: `qa/docdb`, `qa/ses`, and `shared/rds`. The MySQL
credential is stored once and both environments' IAM policies allow reading the
shared prefix, rather than copying the same password into every environment.

## 5. The application's permissions are scoped to one environment

```bash
# variable form
aws iam get-policy-version \
  --policy-arn $(terraform -chdir=$PROJECT_ROOT/terraform/environments/qa output -raw app_policy_arn) \
  --version-id v1 --query 'PolicyVersion.Document' --output json | jq '.Statement[].Sid'

# expanded
aws iam get-policy-version \
  --policy-arn arn:aws:iam::950639281723:policy/mongo-dcu-pipeline-qa-app \
  --version-id v1 --query 'PolicyVersion.Document' --output json | jq '.Statement[].Sid'
```

Five statements. Check that the S3 resources are **qa's five buckets by name**,
not a wildcard - qa's role cannot reach prod's buckets even by accident.

There is no role yet, only the policy:

```bash
terraform -chdir=$PROJECT_ROOT/terraform/environments/qa output irsa_status
# "(no role yet - the cluster's OIDC provider arrives in Phase 7)"
```

That is deliberate. An IRSA role's trust policy names the cluster's OIDC
provider, which does not exist until the cluster does. The permissions are
written, reviewable and version-controlled a phase before there is anything to
attach them to.

## 6. Destroying qa leaves the data tier alone

The property the whole three-stack split exists for.

```bash
terraform -chdir=$PROJECT_ROOT/terraform/environments/qa destroy
./scripts/status.sh | sed -n '/^RDS/,/^VPC/p'
```

The RDS instance is still there, still `available`, with its run history and
any outstanding promotion tokens. qa is gone. This is what would not be true if
the shared instance lived in the qa stack.

## 7. nuke.sh can be inspected without being armed

```bash
./scripts/nuke.sh --dry-run
```

Lists what it would delete, deletes nothing, exits 0. Check the top of the
output:

```
  protected, will not be touched:
    mongo-dcu-pipeline-tfstate-950639281723
    mongo-dcu-pipeline-analytics-exports-950639281723
    mongo-dcu-pipeline-app
```

**Run this before the real thing. Always.** Issue 9 in `docs/ISSUES.md` is what
happens otherwise, and it was a near miss rather than a clean catch.

## 8. The full teardown sequence

```bash
./scripts/teardown.sh
```

Five stages, in an order that cannot be got wrong by accident: status →
`terraform destroy` of qa, prod and the data tier → status → `nuke.sh` →
status. A stack that fails to destroy is deliberately **not** fatal - that is
precisely the case the nuke step exists for, and stopping there would skip it.

The final status should end:

```
cost
  billable resources running: 0
  ok nothing billable is running
```

### Do not verify with the tag query

The obvious independent check is the tag query, and it is the wrong one:

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=project,Values=mongo-dcu-pipeline \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | sort
```

Immediately after a successful teardown this still lists VPC endpoints,
subnets, security group rules and a peering connection. **They do not exist.**
The Resource Groups Tagging API is eventually consistent and keeps returning
ARNs for deleted resources for minutes or hours (issue 11).

Ask each service directly instead - this is what `status.sh` does, and what
makes its answer trustworthy:

```bash
aws ec2 describe-vpcs --region us-east-1 \
  --filters Name=tag:project,Values=mongo-dcu-pipeline --query 'length(Vpcs)' --output text
aws ec2 describe-vpc-endpoints --region us-east-1 --query 'length(VpcEndpoints)' --output text
aws rds describe-db-instances  --region us-east-1 --query 'length(DBInstances)' --output text
aws secretsmanager list-secrets --region us-east-1 --query 'length(SecretList)' --output text
```

All four should be `0`. What remains in the account: the state bucket, the
analytics bucket, the ECR repository, and the five dev buckets.

## What this phase does not prove

- **That a pod can reach any of it.** There is no cluster. The peering DNS
  resolution, the endpoints and the IRSA role are all verified for the first
  time in Phase 8, when the application actually connects.
- **That the DocumentDB TLS setup works end to end.** The CA bundle is in the
  image and the URI is built correctly, but nothing has opened a connection
  with it yet.
- **That the RDS schema exists.** `sql/schema.sql` is applied by Ansible in
  Phase 7.
