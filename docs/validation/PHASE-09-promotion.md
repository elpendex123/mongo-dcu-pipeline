# Phase 9 - prod and the promotion gate

**What this phase built:** the prod environment - the same shape as qa, in its
own VPC, peered to the same data tier - and the gate between them. A fully
successful qa run now issues a single-use token; `scripts/promote.sh` copies a
file to prod only for that exact file, once, before the token expires; and prod
refuses, on its own, any file that was never promoted or has already run.

**Cost:** qa and prod fully up with the data tier is **$0.594/hr** - 23
billable resources. The full cycle below is about an hour and a half. Tear both
down together at the end.

## Variables used in this guide

Repeated here so the page stands alone; the full list, including the values AWS
generates, is in [README.md](README.md).

```bash
export PROJECT_ROOT=~/Documents/PROJECTS/mongo-dcu-pipeline
export PROJECT=mongo-dcu-pipeline
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CHART=$PROJECT_ROOT/helm/$PROJECT-app
export RELEASE=$PROJECT-app
```

| Variable | Example value | Where it comes from |
|---|---|---|
| `PROJECT_ROOT` | `~/Documents/PROJECTS/mongo-dcu-pipeline` | Wherever you cloned the repository |
| `PROJECT` | `mongo-dcu-pipeline` | Fixed |
| `AWS_REGION` | `us-east-1` | Fixed |
| `ACCOUNT_ID` | `950639281723` | From `aws sts get-caller-identity` |
| `CHART` | `.../helm/mongo-dcu-pipeline-app` | Derived |
| `RELEASE` | `mongo-dcu-pipeline-app` | Derived: `$PROJECT-app` |

Bucket names are derived: `$PROJECT-<env>-<role>-$ACCOUNT_ID`. The kubeconfig
contexts are `$PROJECT-qa` and `$PROJECT-prod`.

**Generated, not chosen:**

| Value | Example shape | How it is produced |
|---|---|---|
| `TOKEN` | `d3f83d2899acc00b` | 16 hex characters, issued by a fully successful qa run. Read it from that run's JSON report, its log report, its success email or the `runs` table - never predictable |
| `run_id` | `ca125abd-d272-466d-a639-5e3cf30ea332` | The application, one UUID per file processed |
| Report key | `all-good.txt.ca125abd-....report.json` | Source filename + `run_id`. Found by listing the bucket |
| File sha256 | `1d53993e7833ec6fe4db2db2a9cc83b197e49bd60dea836760d2b8beda52dc2a` | `sha256sum` of the file. Printed by `promote.sh` and stored on the qa run |
| Image tag | `d932fe4` | `git rev-parse --short HEAD` when `scripts/build-push.sh` ran |

`$KEY`, `$TOKEN` and `$PKEY` below are set by the line immediately above where
they are used.

## 0. Before you start

```bash
cd $PROJECT_ROOT
.venv/bin/python -m pytest 2>&1 | grep passed        # expect: 131 passed
./scripts/status.sh | tail -6                        # expect: billable resources running: 0
aws ecr describe-images --repository-name $PROJECT-app --region $AWS_REGION \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags' --output text
```

The newest image must be built from the Phase 9 commit or later - earlier
images never issue a token, and prod in them runs whatever lands in its bucket.

## 1. Bring the data tier, qa and prod up

The data tier first - both environments read its outputs. qa and prod after it,
in either order or at the same time; their state files are separate.

```bash
# variable form
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared-data plan -out=/tmp/shared-data.tfplan
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared-data apply /tmp/shared-data.tfplan
terraform -chdir=$PROJECT_ROOT/terraform/environments/qa   plan -out=/tmp/qa.tfplan
terraform -chdir=$PROJECT_ROOT/terraform/environments/prod plan -out=/tmp/prod.tfplan
terraform -chdir=$PROJECT_ROOT/terraform/environments/qa   apply /tmp/qa.tfplan
terraform -chdir=$PROJECT_ROOT/terraform/environments/prod apply /tmp/prod.tfplan

# expanded
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/prod plan -out=/tmp/prod.tfplan
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/prod apply /tmp/prod.tfplan
```

Read the prod plan before applying it. Expect **72 to add**, the same as qa, and:

- `cidr_block = "10.20.0.0/16"` - the range the data tier's MySQL rule already admits
- seven interface endpoints: `ec2 ecr.api ecr.dkr email logs secretsmanager sts`
- `"system:serviceaccount:prod:mongo-dcu-pipeline-app"` in the trust policy
- `mongo-dcu-pipeline/prod/*` in the secrets statement, and nothing naming `qa`
- `http_put_response_hop_limit = 1`, and nothing matching `nat`

On the live run the data tier took about 7 minutes; qa and prod, applied
together, about 15 each. Then:

```bash
./scripts/status.sh | sed -n '/^cost/,$p'
```

**23** billable resources at **$0.594/hr**: for each environment one cluster,
two nodes, one DocumentDB instance and seven endpoints (11), times two, plus one
shared RDS instance. Count them.

## 2. Configure both clusters

One at a time - both write `~/.kube/config`.

```bash
# variable form
cd $PROJECT_ROOT/ansible
ansible-playbook playbooks/configure-cluster.yml -e target_env=qa
ansible-playbook playbooks/configure-cluster.yml -e target_env=prod

# expanded
cd ~/Documents/PROJECTS/mongo-dcu-pipeline/ansible
ansible-playbook playbooks/configure-cluster.yml -e target_env=prod
```

Each ends `failed=0` with `all 13 of 13 in-cluster checks ran and passed`. The
cross-environment bucket check uses a dev bucket, so it means the same thing in
prod as in qa.

Running a playbook from a background job or a CI step that captures its output?
Redirect it to a file and give it an empty stdin, or it refuses to start
(issue 23):

```bash
ansible-playbook playbooks/configure-cluster.yml -e target_env=prod < /dev/null > configure-prod.log 2>&1
```

## 3. Seed and deploy both

```bash
# variable form
ansible-playbook playbooks/documentdb-reset.yml -e target_env=qa
ansible-playbook playbooks/documentdb-reset.yml -e target_env=prod
cd $PROJECT_ROOT
for ENV in qa prod; do
  helm upgrade --install $RELEASE $CHART --kube-context $PROJECT-$ENV -n $ENV \
    -f $CHART/values-$ENV.yaml -f ansible/generated/values-$ENV.yaml --wait --timeout 5m
done

# expanded (prod)
helm upgrade --install mongo-dcu-pipeline-app helm/mongo-dcu-pipeline-app \
  --kube-context mongo-dcu-pipeline-prod -n prod \
  -f helm/mongo-dcu-pipeline-app/values-prod.yaml -f ansible/generated/values-prod.yaml --wait --timeout 5m
```

`$ENV` is set by the `for` line. Both releases `deployed`, revision 1. The prod
pod's log should show `env=prod`, `connected to the run history database` - its
first connection across its own peering - and `starting the polling loop`.

## 4. The promotion tests

Six tests. Each has one expected outcome and names the check responsible.

### T1 - a valid promotion runs once in prod

```bash
# variable form
aws s3 cp samples/all-good.txt s3://$PROJECT-qa-input-$ACCOUNT_ID/all-good.txt
# about 20 seconds, then:
KEY=$(aws s3 ls s3://$PROJECT-qa-reports-json-$ACCOUNT_ID/ | awk '{print $4}' | grep '^all-good.txt\.' | tail -n 1)
TOKEN=$(aws s3 cp s3://$PROJECT-qa-reports-json-$ACCOUNT_ID/$KEY - | jq -r .promotion.token)
./scripts/promote.sh --file samples/all-good.txt --token $TOKEN --yes

# expanded
aws s3 cp samples/all-good.txt s3://mongo-dcu-pipeline-qa-input-950639281723/all-good.txt
KEY=$(aws s3 ls s3://mongo-dcu-pipeline-qa-reports-json-950639281723/ | awk '{print $4}' | grep '^all-good.txt\.' | tail -n 1)
TOKEN=$(aws s3 cp s3://mongo-dcu-pipeline-qa-reports-json-950639281723/$KEY - | jq -r .promotion.token)
./scripts/promote.sh --file samples/all-good.txt --token $TOKEN --yes
```

The qa log shows `issued promotion token promotion_token=...` and
`run finished status=success ... total_lines=9 success=9`. `promote.sh` prints
four stages - preconditions, checks, claim, copy - each `ok`, and exits 0:

```
2/4  checks
  ok   every check passed: qa run ca125abd-... succeeded on this exact file, token unused, expires 2026-09-15 17:41:32 UTC
3/4  claim the token
  ok token claimed - qa run ca125abd-...
```

Within a polling cycle prod's log reads `prod run authorised
promoted_from_run_id=ca125abd-...`, then `run finished status=success ...
success=9`, and the file is in prod's successful bucket. The prod report says
where it came from:

```bash
PKEY=$(aws s3 ls s3://$PROJECT-prod-reports-json-$ACCOUNT_ID/ | awk '{print $4}' | grep '^all-good.txt\.' | tail -n 1)
aws s3 cp s3://$PROJECT-prod-reports-json-$ACCOUNT_ID/$PKEY - | jq '{environment, status, promoted_from_run_id, promotion}'
```

`"status": "success"`, the qa `run_id` as `promoted_from_run_id`, and
`"promotion": null` - prod spends tokens, it never issues them.

### T2 - the same token again is refused

```bash
./scripts/promote.sh --file samples/all-good.txt --token $TOKEN --yes; echo "exit=$?"
aws s3 ls s3://$PROJECT-prod-input-$ACCOUNT_ID/
```

```
  FAIL used: the token has already promoted a file, and is honoured once
 ERR promotion refused - nothing was claimed and nothing was copied
exit=1
```

The input bucket is empty. Only `used` fails - the hash and expiry were fine.

### A fresh token for T3 to T5

T3 to T5 need an unused token for the same file. `all-good.txt` changes the
data it matches, so reseed qa first, or its second run fails (issue 22):

```bash
cd $PROJECT_ROOT/ansible && ansible-playbook playbooks/documentdb-reset.yml -e target_env=qa && cd ..
aws s3 cp samples/all-good.txt s3://$PROJECT-qa-input-$ACCOUNT_ID/all-good-rerun.txt
# about 20 seconds, then:
KEY=$(aws s3 ls s3://$PROJECT-qa-reports-json-$ACCOUNT_ID/ | awk '{print $4}' | grep '^all-good-rerun.txt\.' | tail -n 1)
TOKEN=$(aws s3 cp s3://$PROJECT-qa-reports-json-$ACCOUNT_ID/$KEY - | jq -r .promotion.token)
```

The key name does not matter to the gate - the hash does. Same bytes, same
hash, new token.

### T3 - one changed byte is refused

```bash
sed 's/Reston/Restom/' samples/all-good.txt > /tmp/all-good.txt
./scripts/promote.sh --file /tmp/all-good.txt --token $TOKEN --yes; echo "exit=$?"
```

```
  FAIL hash: the submitted file is sha256 220ab783... but qa run 042055ac-... validated 1d53993e... - the file has changed since it passed
exit=1
```

A valid, unused, unexpired token, on a file one letter different from the one
it was issued for. Only `hash` fails.

### T4 - an expired token is refused

Waiting 24 hours is not a test. Move the expiry into the past, try, then put it
back:

```bash
MYSQL_SECRET=$(aws secretsmanager get-secret-value --secret-id $PROJECT/shared/rds \
  --region $AWS_REGION --query SecretString --output text) \
.venv/bin/python -c '
import json, os, sys, pymysql
s = json.loads(os.environ["MYSQL_SECRET"])
c = pymysql.connect(host=s["host"], user=s["username"], password=s["password"], database=s["database"], autocommit=True)
print(c.cursor().execute("UPDATE runs SET token_expires_at = UTC_TIMESTAMP() - INTERVAL 1 MINUTE WHERE promotion_token = %s", (sys.argv[1],)), "row expired")
' $TOKEN

./scripts/promote.sh --file samples/all-good.txt --token $TOKEN --yes; echo "exit=$?"
```

```
  FAIL expired: the token expired at 2026-09-14 17:43:46 UTC
exit=1
```

Only `expired` fails. Restore it with the same snippet, `- INTERVAL 1 MINUTE`
changed to `+ INTERVAL 1 HOUR`, before T5.

### T5 - a second promotion of a file prod has run is refused by prod

```bash
./scripts/promote.sh --file samples/all-good.txt --token $TOKEN --yes; echo "exit=$?"
```

This one **passes the gate** - the token is valid for this exact file - is
claimed, and copies. `exit=0`. The gate cannot know prod already ran the file;
prod can:

```
msg="run finished" status=refused destination_bucket=mongo-dcu-pipeline-prod-failed-950639281723 total_lines=9 success=0
  promoted_from_run_id=042055ac-...
  refusal_reason="this file has already run in prod (run d7fb377f-...) - a file runs in production once, and running its writes a second time is a data problem, not a retry"
```

Nothing executed; the file is in prod's failed bucket with a report and a
`REFUSED` email saying why.

### T6 - a file put in prod's bucket by hand is refused

The gate is a script, and a bucket is only a bucket. Bypass the script:

```bash
aws s3 cp samples/execution-defects.txt s3://$PROJECT-prod-input-$ACCOUNT_ID/
```

```
msg="run finished" status=refused ... total_lines=4 success=0
  refusal_reason="no promotion authorises this file - it has to pass qa in full and be promoted with that run's token by scripts/promote.sh; ..."
```

Its report counts all four query lines as `not_run`. Nothing ran.

## 5. The run history agrees

```bash
MYSQL_SECRET=$(aws secretsmanager get-secret-value --secret-id $PROJECT/shared/rds \
  --region $AWS_REGION --query SecretString --output text) \
.venv/bin/python -c '
import json, os, pymysql
s = json.loads(os.environ["MYSQL_SECRET"])
c = pymysql.connect(host=s["host"], user=s["username"], password=s["password"], database=s["database"])
cur = c.cursor()
cur.execute("SELECT environment, file_name, status, promotion_token, token_used, promoted_from_run_id FROM runs ORDER BY started_at")
for row in cur.fetchall(): print(row)
cur.execute("SELECT environment, type, COUNT(*) FROM email_notifications GROUP BY environment, type")
for row in cur.fetchall(): print(row)
'
```

From the live run, oldest first:

| environment | file | status | token | used | promoted from |
|---|---|---|---|---|---|
| qa | all-good.txt | success | `d3f83d28...` | 1 | - |
| prod | all-good.txt | success | - | 0 | the first qa run |
| qa | all-good-rerun.txt | success | `5489a313...` | 1 | - |
| prod | execution-defects.txt | refused | - | 0 | - |
| prod | all-good.txt | refused | - | 0 | the second qa run |

And notifications: qa `success` 2, prod `success` 1, prod `refused` 2. One shared
instance, so the whole story - both environments - is one query.

## 6. Teardown

Uninstall both releases, then destroy qa and prod before the data tier - each
owns a peering connection and a route into it.

```bash
# variable form
for ENV in qa prod; do helm uninstall $RELEASE --kube-context $PROJECT-$ENV -n $ENV --wait; done
for ENV in qa prod; do
  terraform -chdir=$PROJECT_ROOT/terraform/environments/$ENV plan -destroy -out=/tmp/$ENV-destroy.tfplan
  terraform -chdir=$PROJECT_ROOT/terraform/environments/$ENV apply /tmp/$ENV-destroy.tfplan
done
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared-data plan -destroy -out=/tmp/shared-data-destroy.tfplan
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared-data apply /tmp/shared-data-destroy.tfplan

# expanded (prod)
helm uninstall mongo-dcu-pipeline-app --kube-context mongo-dcu-pipeline-prod -n prod --wait
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/prod plan -destroy -out=/tmp/prod-destroy.tfplan
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/prod apply /tmp/prod-destroy.tfplan
```

`72 to destroy` for each environment, then `22`. Or `./scripts/teardown.sh`,
which does all three in order. Finish with:

```bash
./scripts/nuke.sh --dry-run --skip-dev    # expect: nothing to delete
./scripts/status.sh | tail -6             # expect: billable resources running: 0
```

## What this phase does not prove

- **Jenkins.** The gate is a script a Jenkins job will wrap in Phase 12; here it
  ran from a terminal.
- **Graceful shutdown with a file in flight.** Still untested - both uninstalls
  happened between files.
- **Two promotions racing on one token.** The claim is a conditional `UPDATE`
  requiring exactly one changed row, and a second claim on a used token was
  refused against a local MySQL - but two simultaneous claims were not run.
- **Prometheus and Splunk.** Phases 10 and 11.
