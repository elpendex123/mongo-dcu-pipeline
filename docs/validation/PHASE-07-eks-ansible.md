# Phase 7 - EKS and Ansible

**What this phase built:** the EKS module and its wiring into qa, the IRSA
role, eleven Ansible playbooks, and EKS-aware `status.sh`, `nuke.sh` and
`teardown.sh`.

**Cost:** qa with its cluster, plus the data tier, is about **$0.296/hr** - the
$0.154/hr of Phase 6 plus $0.10 for the control plane and $0.042 for two nodes.
Run `teardown.sh` at the end of the session.

> **Since Phase 8** the qa stack has a seventh interface endpoint (SES) and the
> smoke tests run thirteen checks. Applying qa today reports 12 billable
> resources at $0.306/hr, and `configure-cluster.yml` ends with `all 13 of 13
> in-cluster checks ran and passed`.
> [PHASE-08-helm-first-run.md](PHASE-08-helm-first-run.md) is the current guide
> for bringing qa up; this one stays as the record of what Phase 7 proved.

## Variables used in this guide

Repeated here so the page stands alone; the full list, including the values AWS
generates, is in [README.md](README.md).

```bash
export PROJECT_ROOT=~/Documents/PROJECTS/mongo-dcu-pipeline
export PROJECT=mongo-dcu-pipeline
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ENV=qa
export CLUSTER_NAME=$PROJECT-$ENV
```

| Variable | Example value | Where it comes from |
|---|---|---|
| `PROJECT_ROOT` | `~/Documents/PROJECTS/mongo-dcu-pipeline` | Wherever you cloned the repository |
| `PROJECT` | `mongo-dcu-pipeline` | Fixed |
| `AWS_REGION` | `us-east-1` | Fixed |
| `ACCOUNT_ID` | `950639281723` | From `aws sts get-caller-identity` |
| `ENV` | `qa` | Fixed for this phase - prod arrives in Phase 9 |
| `CLUSTER_NAME` | `mongo-dcu-pipeline-qa` | Derived: `$PROJECT-$ENV` |

**Generated, not chosen** - read from an output or a command, never typed:

| Value | Example shape | How it is produced |
|---|---|---|
| API server endpoint | `https://4F1C8A903B2E4D179C551E0A7F6B2D84.gr7.us-east-1.eks.amazonaws.com` | Assigned at cluster creation. `terraform output -raw cluster_endpoint` |
| OIDC issuer | `oidc.eks.us-east-1.amazonaws.com/id/4F1C8A903B2E4D179C551E0A7F6B2D84` | One per cluster, assigned at creation |
| IRSA role ARN | `arn:aws:iam::950639281723:role/mongo-dcu-pipeline-qa-app` | Name derived, ARN from `terraform output -raw irsa_role_arn` |
| Node names | `ip-10-10-3-117.ec2.internal` | The node's private address, assigned at launch |
| Image tag | `2f5ed73` | `git rev-parse --short` at build time. The playbooks pick the newest pushed commit tag |
| `admin_cidr` | `108.45.138.62/32` | Your public address, detected at apply time - by the RDS rule and the EKS API allowlist separately |

## 0. One-time setup

```bash
cd $PROJECT_ROOT
.venv/bin/pip install -r ansible/requirements.txt
ansible-galaxy collection install -r ansible/requirements.yml
cd ansible && ansible-playbook playbooks/prereqs.yml
```

Expect `failed=0`, six tools listed, and your AWS caller ARN at the end.

The image the cluster runs must contain the RDS certificate bundle (issue 12).
Check the newest commit tag in the registry is `2f5ed73` or later:

```bash
aws ecr describe-images --repository-name $PROJECT-app --region $AWS_REGION \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags' --output text

# expanded
aws ecr describe-images --repository-name mongo-dcu-pipeline-app --region us-east-1 \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags' --output text
```

## 1. Apply, in order

```bash
# variable form
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared-data apply
terraform -chdir=$PROJECT_ROOT/terraform/environments/$ENV apply

# expanded
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/shared-data apply
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/qa apply
```

The data tier adds 22 resources in about five minutes. qa adds 71; the first
live run took **14 minutes**, most of it DocumentDB and the EKS control plane,
then the node group waiting for both nodes to join.

Read the qa plan before typing `yes`. It should include:

- `module.eks.aws_eks_cluster.this` and `module.eks.aws_eks_node_group.this`
- `module.iam.aws_iam_role.app[0]` - the IRSA role. Its absence, or an
  `Invalid count argument` error, is issue 13
- `http_put_response_hop_limit = 1` and `http_tokens = "required"` on the
  launch template
- `"system:serviceaccount:qa:mongo-dcu-pipeline-app"` in the trust policy
- nothing matching `nat`

`public_access_cidrs` shows `(known after apply)`. That is expected, not a
problem: the EKS module waits on the endpoints module, and a `depends_on` on a
module postpones every data source inside it - including the lookup of your
public address - until apply.

## 2. status.sh adds up

```bash
cd $PROJECT_ROOT && ./scripts/status.sh
```

**Count the billable resources against the report:** one EKS cluster, two
nodes, one DocumentDB instance, six interface endpoints, one RDS instance -
**11**, at about **$0.296/hr**. The EKS section should also show:

- `API public access` naming your address as a `/32`, and no warning under it
- three add-ons, `vpc-cni`, `kube-proxy`, `coredns`, each `ACTIVE`
- one node group, `ACTIVE`, `2 x t3.small`, and two instances in different AZs

## 3. Configure the cluster

```bash
# variable form
cd $PROJECT_ROOT/ansible && ansible-playbook playbooks/configure-cluster.yml -e target_env=$ENV

# expanded
cd ~/Documents/PROJECTS/mongo-dcu-pipeline/ansible && ansible-playbook playbooks/configure-cluster.yml -e target_env=qa
```

Expect `failed=0` in the recap. The two sections worth reading as they scroll
past:

- **Secrets bridge** reports key names only, never values - three Secrets with
  `MONGO_URI`; the five `MYSQL_*` keys; `SES_RECIPIENTS, SES_SENDER`.
- **Smoke tests** ends with twelve lines, each `PASS`, and
  `all 12 of 12 in-cluster checks ran and passed`. Count them: the first live
  run passed on seven, because a hung check was never counted (issue 16).

If a smoke test fails, the line names the check and the error. The table in
[ANSIBLE.md](../ANSIBLE.md#the-smoke-tests) says what each one proves, and
[KUBERNETES.md](../KUBERNETES.md#when-something-is-wrong) what to look at.

## 4. Look at the cluster by hand

```bash
# variable form
kubectl --context $CLUSTER_NAME get nodes -o wide
kubectl --context $CLUSTER_NAME get pods -A
kubectl --context $CLUSTER_NAME get namespace $ENV --show-labels

# expanded
kubectl --context mongo-dcu-pipeline-qa get nodes -o wide
kubectl --context mongo-dcu-pipeline-qa get pods -A
kubectl --context mongo-dcu-pipeline-qa get namespace qa --show-labels
```

Two nodes `Ready`, with `10.10.x.x` internal addresses and **no external IP**.
System pods all `Running`. The `qa` namespace labelled
`pod-security.kubernetes.io/enforce=restricted`.

## 5. The IRSA trust policy names one service account

```bash
aws iam get-role --role-name $PROJECT-$ENV-app \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json

# expanded
aws iam get-role --role-name mongo-dcu-pipeline-qa-app \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json
```

Two `StringEquals` conditions on the cluster's issuer: `:aud` is
`sts.amazonaws.com`, and `:sub` is
`system:serviceaccount:qa:mongo-dcu-pipeline-app`. Then the other half of the
binding:

```bash
kubectl --context $CLUSTER_NAME -n $ENV get serviceaccount $PROJECT-app \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}'

# expanded
kubectl --context mongo-dcu-pipeline-qa -n qa get serviceaccount mongo-dcu-pipeline-app \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}'
```

The ARN printed must be the role above.

## 6. Pods cannot use the node's credentials

The smoke tests check this from inside a pod. The setting behind it is on the
instances:

```bash
aws ec2 describe-instances --region $AWS_REGION \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,MetadataOptions.HttpTokens,MetadataOptions.HttpPutResponseHopLimit]' \
  --output table
```

Each row: `required`, `1`.

## 7. Secrets reached the cluster, values stayed out of the logs

```bash
kubectl --context $CLUSTER_NAME -n $ENV get secrets -l app.kubernetes.io/managed-by=ansible
kubectl --context $CLUSTER_NAME -n $ENV get secret $PROJECT-rds -o jsonpath='{.data}' | jq 'keys'

# expanded
kubectl --context mongo-dcu-pipeline-qa -n qa get secrets -l app.kubernetes.io/managed-by=ansible
kubectl --context mongo-dcu-pipeline-qa -n qa get secret mongo-dcu-pipeline-rds -o jsonpath='{.data}' | jq 'keys'
```

Three Secrets; the second command lists key names. Then confirm no Secret
carries a copy of itself in an annotation (the reason the bridge replaces
rather than applies):

```bash
kubectl --context $CLUSTER_NAME -n $ENV get secrets -o json \
  | jq '[.items[].metadata.annotations // {} | has("kubectl.kubernetes.io/last-applied-configuration")] | any'
```

Expect `false`.

## 8. Reset DocumentDB from inside the cluster

```bash
cd $PROJECT_ROOT/ansible && ansible-playbook playbooks/documentdb-reset.yml -e target_env=$ENV
```

The seeder's own output is printed: connecting (with the password redacted),
dropping the collection, creating five indexes, inserting 100 documents.

Between the first two lines pymongo prints a `UserWarning: You appear to be
connected to a DocumentDB cluster`. It is informational - the driver noticing
the endpoint's hostname - and appears on every connection. The line that
matters is `inserted 100 documents`. Run
it twice - the second run should look identical, because the reset is a drop,
not a delete.

## 9. The Helm values and the structured status

```bash
cd $PROJECT_ROOT/ansible
cat generated/values-$ENV.yaml
ansible-playbook playbooks/status.yml && jq . generated/status.json
```

The values file names the image tag, the IRSA role ARN, `APP_ENV: "qa"` and
the five bucket names - check `APP_ENV` in particular (issue 15). The status
document should agree with `status.sh` on the count: 11.

## 10. Teardown

```bash
cd $PROJECT_ROOT && ./scripts/teardown.sh
```

On the first live run the qa destroy took 14 minutes (the node group and the
DocumentDB instance are the slow part) and the data tier 2.

To see exactly what will be deleted before it is, do each stack by hand with a
saved plan - destroy qa first, because it owns the peering connection and the
route into the data tier:

```bash
# variable form
terraform -chdir=$PROJECT_ROOT/terraform/environments/$ENV plan -destroy -out=/tmp/$ENV-destroy.tfplan
terraform -chdir=$PROJECT_ROOT/terraform/environments/$ENV apply /tmp/$ENV-destroy.tfplan
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared-data plan -destroy -out=/tmp/shared-data-destroy.tfplan
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared-data apply /tmp/shared-data-destroy.tfplan

# expanded
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/qa plan -destroy -out=/tmp/qa-destroy.tfplan
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/qa apply /tmp/qa-destroy.tfplan
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/shared-data plan -destroy -out=/tmp/shared-data-destroy.tfplan
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/shared-data apply /tmp/shared-data-destroy.tfplan
```

Expect `71 to destroy` then `22 to destroy`, and nothing listed that is not
being destroyed. Then `./scripts/nuke.sh --dry-run --skip-dev` and
`./scripts/status.sh`.

At the end:

- `billable resources running: 0`
- `IAM and launch templates` reads `none`
- `kubectl config get-contexts` no longer lists `mongo-dcu-pipeline-qa`

**Do not verify with the tag query** - it lags deletions (issue 11). Count with
each service instead:

```bash
aws eks list-clusters --region $AWS_REGION --query 'length(clusters)'
aws iam list-open-id-connect-providers --query 'length(OpenIDConnectProviderList)'
aws ec2 describe-instances --region $AWS_REGION \
  --filters "Name=tag:project,Values=$PROJECT" "Name=instance-state-name,Values=pending,running" \
  --query 'length(Reservations)'
```

All three `0`, unless the account holds OIDC providers for other projects.

## What this phase does not prove

- **The application running in the cluster.** The smoke tests use the
  application's image, identity and Secrets, but not its process - that is the
  Helm chart, Phase 8.
- **SES.** Sender and recipient identities are not verified yet, and the
  rendered values keep `SES_ENABLED: "false"` until they are.
- **prod.** Nothing here has been applied with `target_env=prod`; the prod stack
  does not exist until Phase 9.
