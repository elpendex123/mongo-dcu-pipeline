# Phase 8 - Helm and the first cloud run

**What this phase built:** the application's Helm chart, the SES endpoint and
the IAM sender restriction, bounded timeouts on the application's AWS clients,
and the first file processed end to end in AWS: validated, executed against
DocumentDB, routed, reported, recorded in MySQL, and emailed. Then a
deliberately broken deploy and a rollback.

**Cost:** qa with its cluster and the data tier is about **$0.306/hr** - Phase
7's $0.296 plus $0.01 for the SES endpoint. The full cycle below is a little
over an hour. Tear down at the end.

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
export RELEASE=$PROJECT-app
export CHART=$PROJECT_ROOT/helm/$PROJECT-app
export SES_ADDRESS=enrique.coello@gmail.com
```

| Variable | Example value | Where it comes from |
|---|---|---|
| `PROJECT_ROOT` | `~/Documents/PROJECTS/mongo-dcu-pipeline` | Wherever you cloned the repository |
| `PROJECT` | `mongo-dcu-pipeline` | Fixed |
| `AWS_REGION` | `us-east-1` | Fixed |
| `ACCOUNT_ID` | `950639281723` | From `aws sts get-caller-identity` |
| `ENV` | `qa` | Fixed for this phase |
| `CLUSTER_NAME` | `mongo-dcu-pipeline-qa` | Derived: `$PROJECT-$ENV`. Also the kubeconfig context |
| `RELEASE` | `mongo-dcu-pipeline-app` | Derived: `$PROJECT-app` |
| `CHART` | `.../helm/mongo-dcu-pipeline-app` | Derived |
| `SES_ADDRESS` | `enrique.coello@gmail.com` | Your choice - the address verified in SES, used as sender and recipient |

The bucket names below are derived too: `$PROJECT-$ENV-<role>-$ACCOUNT_ID`.

**Generated, not chosen:**

| Value | Example shape | How it is produced |
|---|---|---|
| Image tag | `9733c70` | `git rev-parse --short HEAD` when `scripts/build-push.sh` ran |
| `run_id` | `c4916ff8-75c6-4ace-b516-b54d10505f37` | The application, one UUID per file processed |
| Report key | `all-good.txt.c4916ff8-....report.log` | Source filename + `run_id` |
| Helm revision | `1`, `2`, `3`, `4` | Helm, one per install, upgrade and rollback |
| Pod name | `mongo-dcu-pipeline-app-5886978844-btfrh` | Kubernetes, new on every restart - use `deploy/$RELEASE` instead |

## 0. Before you start

The SES identity must be verified in us-east-1. In sandbox mode both sender and
recipient must be; this project uses one address for both:

```bash
# variable form
aws sesv2 get-email-identity --email-identity $SES_ADDRESS --region $AWS_REGION --query VerificationStatus

# expanded
aws sesv2 get-email-identity --email-identity enrique.coello@gmail.com --region us-east-1 --query VerificationStatus
```

Expect `"SUCCESS"`. The image in ECR must be `9733c70` or later - earlier
images fill a DEBUG log with pymongo's driver chatter (issue 21):

```bash
aws ecr describe-images --repository-name $PROJECT-app --region $AWS_REGION \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags' --output text
```

## 1. Bring qa up

Exactly as Phase 7 - [PHASE-07-eks-ansible.md](PHASE-07-eks-ansible.md)
sections 1 and 3 - with three differences to look for:

- the qa plan adds **72** resources, one more than Phase 7: the `email` endpoint
- the plan shows `ses:FromAddress` in the application's IAM policy
- `status.sh` counts **12** billable resources at **$0.306/hr**, with `email`
  among the seven interface endpoints

On the first live run the data tier took 7 minutes and qa 15.

`configure-cluster.yml` must end with `all 13 of 13 in-cluster checks ran and
passed` - the thirteenth is `SES API reachable through its endpoint`. Then seed
the data the samples query:

```bash
cd $PROJECT_ROOT/ansible && ansible-playbook playbooks/documentdb-reset.yml -e target_env=$ENV
```

## 2. Render and check the chart before installing

```bash
# variable form
cd $PROJECT_ROOT
helm lint $CHART -f $CHART/values-$ENV.yaml -f ansible/generated/values-$ENV.yaml
helm template $RELEASE $CHART -n $ENV -f $CHART/values-$ENV.yaml -f ansible/generated/values-$ENV.yaml \
  | kubectl --context $CLUSTER_NAME apply --dry-run=server -f -

# expanded
cd ~/Documents/PROJECTS/mongo-dcu-pipeline
helm template mongo-dcu-pipeline-app helm/mongo-dcu-pipeline-app -n qa \
  -f helm/mongo-dcu-pipeline-app/values-qa.yaml -f ansible/generated/values-qa.yaml \
  | kubectl --context mongo-dcu-pipeline-qa apply --dry-run=server -f -
```

Expect three lines ending `(server dry run)`: ConfigMap, Service, Deployment.
The server-side dry run passes the pod through Pod Security admission, so a
`restricted` violation shows up here rather than as a pod that never appears.

Try the guards - each must fail with a message naming the problem:

```bash
helm template x $CHART -f $CHART/values-$ENV.yaml 2>&1 | head -1
helm template x $CHART -f $CHART/values-$ENV.yaml -f ansible/generated/values-$ENV.yaml --set image.tag=latest 2>&1 | head -1
```

`config.APP_ENV is required ...` and `image.tag must name a commit, not latest ...`.

## 3. Install

```bash
# variable form
helm upgrade --install $RELEASE $CHART --kube-context $CLUSTER_NAME -n $ENV \
  -f $CHART/values-$ENV.yaml -f ansible/generated/values-$ENV.yaml --wait --timeout 5m

# expanded
helm upgrade --install mongo-dcu-pipeline-app helm/mongo-dcu-pipeline-app \
  --kube-context mongo-dcu-pipeline-qa -n qa \
  -f helm/mongo-dcu-pipeline-app/values-qa.yaml -f ansible/generated/values-qa.yaml --wait --timeout 5m
```

`STATUS: deployed`, `REVISION: 1`, and the NOTES naming the image. Then read
the application's own account of starting:

```bash
kubectl --context $CLUSTER_NAME -n $ENV logs deploy/$RELEASE | grep -v 'component=pymongo' | head -8
```

In order: `mongo-dcu-pipeline starting ... email=true`, `metrics endpoint is
listening`, `connected to the document database`, `connected to the run history
database`, `starting the polling loop`, `no files awaiting processing`. That
last line is the first S3 call through IRSA, from the application itself.

Count who is talking, too:

```bash
kubectl --context $CLUSTER_NAME -n $ENV logs deploy/$RELEASE | grep -o 'component=[^ ]*' | sort | uniq -c | sort -rn
```

No `component=pymongo.*` lines. If there are, the image predates issue 21.

## 4. A good file

```bash
# variable form
aws s3 cp $PROJECT_ROOT/samples/all-good.txt s3://$PROJECT-$ENV-input-$ACCOUNT_ID/

# expanded
aws s3 cp ~/Documents/PROJECTS/mongo-dcu-pipeline/samples/all-good.txt s3://mongo-dcu-pipeline-qa-input-950639281723/
```

Within about 20 seconds - one poll interval plus the work - the file leaves the
input bucket:

```bash
for role in input successful failed reports-json reports-log; do
  echo "$role: $(aws s3 ls s3://$PROJECT-$ENV-$role-$ACCOUNT_ID/ | awk '{print $4}' | tr '\n' ' ')"
done
```

`successful: all-good.txt`, and one report in each reports bucket named
`all-good.txt.<run_id>.report.json` / `.report.log`. In the log:
`run finished status=success ... total_lines=9 success=9`.

## 5. A bad file

```bash
aws s3 cp $PROJECT_ROOT/samples/one-bad-line.txt s3://$PROJECT-$ENV-input-$ACCOUNT_ID/
```

It lands in `failed`. Read its report:

```bash
# variable form
KEY=$(aws s3 ls s3://$PROJECT-$ENV-reports-log-$ACCOUNT_ID/ | awk '{print $4}' | grep '^one-bad-line.txt' | tail -1)
aws s3 cp s3://$PROJECT-$ENV-reports-log-$ACCOUNT_ID/$KEY -

# expanded
KEY=$(aws s3 ls s3://mongo-dcu-pipeline-qa-reports-log-950639281723/ | awk '{print $4}' | grep '^one-bad-line.txt' | tail -1)
aws s3 cp s3://mongo-dcu-pipeline-qa-reports-log-950639281723/$KEY -
```

`$KEY` is set by the line above it. The report names **line 7** - comment and
blank lines count - with `'{' opened at col 20 is closed by ')'`, a caret under
the column, and the other three queries marked `--`: valid, never attempted,
because validation runs over the whole file before anything executes.

## 6. The run history

There is no `mysql` client in this project; PyMySQL in `.venv` does the same
job, with the password read from Secrets Manager rather than typed:

```bash
cd $PROJECT_ROOT
MYSQL_SECRET=$(aws secretsmanager get-secret-value --secret-id $PROJECT/shared/rds \
  --region $AWS_REGION --query SecretString --output text) \
.venv/bin/python -c '
import json, os, pymysql
s = json.loads(os.environ["MYSQL_SECRET"])
c = pymysql.connect(host=s["host"], user=s["username"], password=s["password"], database=s["database"])
cur = c.cursor()
cur.execute("SELECT file_name, environment, status, total_lines, success_count, syntax_fail_count FROM runs ORDER BY started_at DESC LIMIT 5")
for row in cur.fetchall(): print(row)
cur.execute("SELECT type, sent_at FROM email_notifications ORDER BY sent_at DESC LIMIT 5")
for row in cur.fetchall(): print(row)
'
```

Two runs - `one-bad-line.txt`, `qa`, `failed`, 4, 0, 1 and `all-good.txt`, `qa`,
`success`, 9, 9, 0 - and a `failure` and a `success` notification.

## 7. The email

Check the inbox of `$SES_ADDRESS` for `[mongo-dcu-pipeline] [qa] SUCCESS:
all-good.txt` and `[mongo-dcu-pipeline] [qa] FAILED: one-bad-line.txt`. The
failure email carries line 7 and its error inline.

SES's own counter confirms the sends, but it lags by a few minutes:

```bash
aws sesv2 get-account --region $AWS_REGION --query SendQuota.SentLast24Hours
```

## 8. The metrics

```bash
kubectl --context $CLUSTER_NAME -n $ENV port-forward deploy/$RELEASE 19090:9090 &
curl -s localhost:19090/metrics | grep -E '^(files_processed_total|lines_failed_total|lines_processed_total|files_waiting)'
kill %1
```

`files_processed_total{status="success"} 1.0`, `{status="failed"} 1.0`,
`lines_failed_total{reason="syntax"} 1.0`, `lines_processed_total{status="success"} 9.0`,
`{status="not_run"} 3.0`, `files_waiting 0.0`. These reset when the pod restarts
- durable history is MySQL's job.

## 9. Break it, then roll back

See [HELM.md](../HELM.md#a-broken-upgrade-on-purpose) for why each command
behaves the way it does.

```bash
# variable form
helm upgrade $RELEASE $CHART --kube-context $CLUSTER_NAME -n $ENV \
  -f $CHART/values-$ENV.yaml -f ansible/generated/values-$ENV.yaml \
  --set image.tag=does-not-exist --wait --timeout 2m

# expanded
helm upgrade mongo-dcu-pipeline-app helm/mongo-dcu-pipeline-app --kube-context mongo-dcu-pipeline-qa -n qa \
  -f helm/mongo-dcu-pipeline-app/values-qa.yaml -f ansible/generated/values-qa.yaml \
  --set image.tag=does-not-exist --wait --timeout 2m
```

After exactly two minutes: `Error: UPGRADE FAILED: context deadline exceeded`.
The pod shows `ImagePullBackOff`, the event says the tag was `not found`, and:

```bash
helm history $RELEASE --kube-context $CLUSTER_NAME -n $ENV
```

```
REVISION  STATUS      DESCRIPTION
1         superseded  Install complete
2         deployed    Upgrade complete
3         failed      Upgrade "mongo-dcu-pipeline-app" failed: context deadline exceeded
```

(Revision 2 exists if you upgraded once before breaking it; on a fresh install,
roll back to 1.) Roll back to the last revision that was not `failed`:

```bash
# variable form
helm rollback $RELEASE 2 --kube-context $CLUSTER_NAME -n $ENV --wait --timeout 5m

# expanded
helm rollback mongo-dcu-pipeline-app 2 --kube-context mongo-dcu-pipeline-qa -n qa --wait --timeout 5m
```

It took 9 seconds on the first live run. History gains revision 4, `deployed`,
`Rollback to 2`. The image is the good tag again:

```bash
kubectl --context $CLUSTER_NAME -n $ENV get deploy $RELEASE -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Because the strategy is `Recreate`, the old pod stopped before the broken one
was tried: **for the two minutes of the failed upgrade, nothing processed
files.** That is the price of never running two pods against one bucket.

## 10. Prove it recovered - with a reset first

A Ready pod is not proof. Give it a file - but reseed first:

```bash
cd $PROJECT_ROOT/ansible && ansible-playbook playbooks/documentdb-reset.yml -e target_env=$ENV && cd ..
aws s3 cp samples/all-good.txt s3://$PROJECT-$ENV-input-$ACCOUNT_ID/all-good-after-rollback.txt
```

Expect `successful`. **Without the reset it fails**, on line 14: its first run
turned Reston's active listings to pending, so the same `updateMany` now
matches nothing, which the pipeline reports as `fail_execution` by design
(issue 22). The live run found this exactly that way.

## 11. Teardown

Uninstall the release first, then destroy qa and the data tier through saved
plans, as in Phase 7:

```bash
# variable form
helm uninstall $RELEASE --kube-context $CLUSTER_NAME -n $ENV --wait
terraform -chdir=$PROJECT_ROOT/terraform/environments/$ENV plan -destroy -out=/tmp/$ENV-destroy.tfplan
terraform -chdir=$PROJECT_ROOT/terraform/environments/$ENV apply /tmp/$ENV-destroy.tfplan
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared-data plan -destroy -out=/tmp/shared-data-destroy.tfplan
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared-data apply /tmp/shared-data-destroy.tfplan

# expanded
helm uninstall mongo-dcu-pipeline-app --kube-context mongo-dcu-pipeline-qa -n qa --wait
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/qa plan -destroy -out=/tmp/qa-destroy.tfplan
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/qa apply /tmp/qa-destroy.tfplan
```

Expect `72 to destroy` then `22 to destroy`. Or `./scripts/teardown.sh`, which
does the destroys, the kubeconfig cleanup and the final sweep in one command.
Finish with `./scripts/status.sh`: `billable resources running: 0`.

## What this phase does not prove

- **The promotion gate.** qa runs do not write a `promotion_token` yet, and
  there is no prod - Phase 9.
- **Graceful shutdown mid-file.** The pod was stopped by upgrades and the
  uninstall, but never while a file was in flight.
- **Prometheus scraping.** The metrics endpoint answers; nothing collects it
  until Phase 10.
- **Splunk.** The log file is written to the shared volume; the sidecar that
  reads it is Phase 11.
