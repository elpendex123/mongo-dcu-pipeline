# Helm

The application ships as one chart, `helm/mongo-dcu-pipeline-app/`, written
from scratch. This page covers how its values are layered, the decisions
built into its templates, and the release lifecycle - install, upgrade, a
deliberately broken upgrade, rollback, uninstall - with every command in both
variable and expanded form.

`kube-prometheus-stack`, the second chart the project uses, is installed before
this one and has a page of its own: [PROMETHEUS-GRAFANA.md](PROMETHEUS-GRAFANA.md).

## Variables used on this page

```bash
export PROJECT_ROOT=~/Documents/PROJECTS/mongo-dcu-pipeline
export PROJECT=mongo-dcu-pipeline
export AWS_REGION=us-east-1
export ENV=qa
export CLUSTER_NAME=$PROJECT-$ENV
export RELEASE=$PROJECT-app
export CHART=$PROJECT_ROOT/helm/$PROJECT-app
```

| Variable | Example value | Where it comes from |
|---|---|---|
| `PROJECT_ROOT` | `~/Documents/PROJECTS/mongo-dcu-pipeline` | Wherever you cloned the repository |
| `PROJECT` | `mongo-dcu-pipeline` | Fixed |
| `AWS_REGION` | `us-east-1` | Fixed |
| `ENV` | `qa` | Your choice: `qa` or `prod`. Also the namespace, because each environment has its own cluster |
| `CLUSTER_NAME` | `mongo-dcu-pipeline-qa` | Derived: `$PROJECT-$ENV`. Also the kubeconfig context name |
| `RELEASE` | `mongo-dcu-pipeline-app` | Derived: `$PROJECT-app`. The release, the Deployment and the ConfigMap all carry this name |
| `CHART` | `~/Documents/PROJECTS/mongo-dcu-pipeline/helm/mongo-dcu-pipeline-app` | Derived |

**Generated, not chosen** - none of these is typed; they arrive in
`ansible/generated/values-$ENV.yaml`, rendered from Terraform outputs by
`ansible/playbooks/render-values.yml`:

| Value | Example shape | How it is produced |
|---|---|---|
| Image tag | `d8865d0` | `git rev-parse --short HEAD` when `scripts/build-push.sh` ran. The newest pushed commit tag is picked |
| IRSA role ARN | `arn:aws:iam::950639281723:role/mongo-dcu-pipeline-qa-app` | Terraform output `irsa_role_arn` |
| Bucket names | `mongo-dcu-pipeline-qa-input-950639281723` | Terraform output `app_config` |
| Revision number | `1`, `2`, `3` | Helm, incremented on every upgrade and rollback. Read with `helm history` |
| Pod name | `mongo-dcu-pipeline-app-7c9f8d6b5d-x2k4q` | Kubernetes, new on every restart. Commands below use `deploy/$RELEASE` so it never has to be typed |

## Layout

```
helm/mongo-dcu-pipeline-app/
  Chart.yaml
  values.yaml          safe defaults, nothing environment-specific
  values-qa.yaml       qa sizing and tuning (LOG_LEVEL=DEBUG)
  values-prod.yaml     prod sizing and tuning
  files/
    grafana-dashboard.json     the application's dashboard
  templates/
    _helpers.tpl               names, labels, and the render-time guards
    configmap.yaml             non-secret environment variables
    deployment.yaml            the application pod
    service.yaml               the metrics port
    servicemonitor.yaml        tells Prometheus to scrape it         (monitoring.enabled)
    prometheusrule.yaml        the application's three alerts        (monitoring.enabled)
    dashboard-configmap.yaml   the dashboard, for Grafana's sidecar  (monitoring.enabled)
    NOTES.txt                  printed after install: logs, a test upload, metrics, rollback
```

There is no `serviceaccount.yaml` and no `hpa.yaml`, both deliberately - see
below.

## Three layers of values

Later files win, key by key:

| File | Committed | Holds |
|---|---|---|
| `values.yaml` | Yes | Defaults: resources, probes, security context, the config keys that are the same everywhere |
| `values-<env>.yaml` | Yes | What differs by environment by choice: log level, sizing |
| `ansible/generated/values-<env>.yaml` | **No** | What differs by environment because AWS assigned it: image, IAM role, bucket names, region |

The split follows the fixed / derived / generated distinction the rest of the
project uses. The first two layers are decisions someone made and are reviewed
in git. The third is facts read from the current apply; a committed copy would
be stale by the next session.

## Decisions in the templates

| Decision | Why |
|---|---|
| `replicas: 1`, hardcoded, no HPA | The application has no locking. A second replica would sooner or later process a file twice, running its writes twice |
| `strategy: Recreate` | A rolling update starts the new pod before stopping the old one, and while both run they poll the same bucket. Recreate accepts a few seconds with no pod instead |
| Service account used, never created | It is the Kubernetes half of the IRSA binding whose IAM half Terraform wrote. Ansible creates it; a chart that could rename it could break the only identity the role trusts |
| `runAsUser: 1001` stated | The image's `USER appuser` is a name, and the `restricted` Pod Security Standard refuses a pod whose user the kubelet cannot prove is not root |
| Read-only root filesystem, two `emptyDir` volumes | The log directory (shared with the Splunk sidecar in Phase 11) and `/tmp` are the only writable paths |
| `checksum/config` annotation | A ConfigMap change does not restart the pods reading it. Hashing it into the pod template does |
| `terminationGracePeriodSeconds: 120` | On SIGTERM the application finishes the file in flight rather than abandoning it half-applied |
| Probes on `/metrics` | The metrics server starts before the startup connectivity checks, so the startup probe allows two minutes for them |
| `automountServiceAccountToken: false` | The application never calls the Kubernetes API. The IRSA token is projected separately by the EKS webhook |

### Render-time guards

The chart fails `helm template` - before anything reaches the cluster - rather
than producing a pod that starts and misbehaves:

| Missing or wrong | Message |
|---|---|
| Generated values not passed | `config.APP_ENV is required - render ansible/generated/values-<env>.yaml and pass it with -f` |
| `image.tag` is `latest` | `image.tag must name a commit, not latest - a moving tag cannot be rolled back to` |
| `AWS_DEFAULT_REGION` absent | `config.AWS_DEFAULT_REGION is required ...` - without it the pod hangs on its first AWS call ([issue 17](ISSUES.md)) |

## Monitoring integration

`monitoring.enabled` adds three objects: a `ServiceMonitor` for the metrics
port, a `PrometheusRule` with the application's alerts, and a ConfigMap holding
its Grafana dashboard. It is `false` in `values.yaml` and `true` in both
environment files.

The first two are kube-prometheus-stack's custom resources, so **the monitoring
release goes in first**: an API server without those definitions refuses them,
and the install fails on the first one. `helm lint` and `helm template` do not
talk to the cluster and pass either way; the server-side dry run below does, and
is where a missing definition shows.

The application ships its own dashboard and rules rather than keeping them in
the monitoring values: a chart version that renames a metric brings the queries
that read it, in the same release. The rules are checked with promtool before
they are committed - see [PROMETHEUS-GRAFANA.md](PROMETHEUS-GRAFANA.md#the-alerts).

## Render and check, without installing

```bash
# variable form
helm lint $CHART -f $CHART/values-$ENV.yaml -f $PROJECT_ROOT/ansible/generated/values-$ENV.yaml
helm template $RELEASE $CHART -n $ENV -f $CHART/values-$ENV.yaml -f $PROJECT_ROOT/ansible/generated/values-$ENV.yaml

# expanded
helm lint ~/Documents/PROJECTS/mongo-dcu-pipeline/helm/mongo-dcu-pipeline-app \
  -f ~/Documents/PROJECTS/mongo-dcu-pipeline/helm/mongo-dcu-pipeline-app/values-qa.yaml \
  -f ~/Documents/PROJECTS/mongo-dcu-pipeline/ansible/generated/values-qa.yaml
```

A server-side dry run sends the rendered objects through the API server's
validation and admission - including the `restricted` Pod Security check -
without creating anything:

```bash
# variable form
helm template $RELEASE $CHART -n $ENV -f $CHART/values-$ENV.yaml -f $PROJECT_ROOT/ansible/generated/values-$ENV.yaml \
  | kubectl --context $CLUSTER_NAME apply --dry-run=server -f -

# expanded
helm template mongo-dcu-pipeline-app ~/Documents/PROJECTS/mongo-dcu-pipeline/helm/mongo-dcu-pipeline-app -n qa \
  -f ~/Documents/PROJECTS/mongo-dcu-pipeline/helm/mongo-dcu-pipeline-app/values-qa.yaml \
  -f ~/Documents/PROJECTS/mongo-dcu-pipeline/ansible/generated/values-qa.yaml \
  | kubectl --context mongo-dcu-pipeline-qa apply --dry-run=server -f -
```

## Lifecycle

### Install or upgrade

`upgrade --install` is the one command for both: it installs when the release
does not exist and upgrades when it does.

```bash
# variable form
helm upgrade --install $RELEASE $CHART --kube-context $CLUSTER_NAME -n $ENV \
  -f $CHART/values-$ENV.yaml -f $PROJECT_ROOT/ansible/generated/values-$ENV.yaml \
  --wait --timeout 5m

# expanded
helm upgrade --install mongo-dcu-pipeline-app ~/Documents/PROJECTS/mongo-dcu-pipeline/helm/mongo-dcu-pipeline-app \
  --kube-context mongo-dcu-pipeline-qa -n qa \
  -f ~/Documents/PROJECTS/mongo-dcu-pipeline/helm/mongo-dcu-pipeline-app/values-qa.yaml \
  -f ~/Documents/PROJECTS/mongo-dcu-pipeline/ansible/generated/values-qa.yaml \
  --wait --timeout 5m
```

`--wait` holds until the pod is Ready or the timeout passes, so a failed
deploy fails the command rather than being discovered later.

### What is running

```bash
# variable form
helm list --kube-context $CLUSTER_NAME -n $ENV
helm history $RELEASE --kube-context $CLUSTER_NAME -n $ENV
kubectl --context $CLUSTER_NAME -n $ENV get deploy $RELEASE -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl --context $CLUSTER_NAME -n $ENV logs deploy/$RELEASE --tail=50

# expanded
helm history mongo-dcu-pipeline-app --kube-context mongo-dcu-pipeline-qa -n qa
kubectl --context mongo-dcu-pipeline-qa -n qa logs deploy/mongo-dcu-pipeline-app --tail=50
```

### A broken upgrade, on purpose

The exercise: deploy an image tag that does not exist, watch it fail, and go
back.

```bash
# variable form
helm upgrade $RELEASE $CHART --kube-context $CLUSTER_NAME -n $ENV \
  -f $CHART/values-$ENV.yaml -f $PROJECT_ROOT/ansible/generated/values-$ENV.yaml \
  --set image.tag=does-not-exist --wait --timeout 2m

# expanded
helm upgrade mongo-dcu-pipeline-app ~/Documents/PROJECTS/mongo-dcu-pipeline/helm/mongo-dcu-pipeline-app \
  --kube-context mongo-dcu-pipeline-qa -n qa \
  -f ~/Documents/PROJECTS/mongo-dcu-pipeline/helm/mongo-dcu-pipeline-app/values-qa.yaml \
  -f ~/Documents/PROJECTS/mongo-dcu-pipeline/ansible/generated/values-qa.yaml \
  --set image.tag=does-not-exist --wait --timeout 2m
```

The command fails after two minutes, and `helm history` shows the new revision
`failed`. Because the strategy is `Recreate`, the old pod was stopped before
the new one was tried - so for those two minutes **nothing is processing
files**. That is the honest cost of refusing to run two pods at once, and the
reason a real deploy uses `--wait`: the failure is known in minutes, not when
someone notices files piling up.

### Rollback

```bash
# variable form
helm history $RELEASE --kube-context $CLUSTER_NAME -n $ENV
helm rollback $RELEASE <revision> --kube-context $CLUSTER_NAME -n $ENV --wait --timeout 5m

# expanded
helm history mongo-dcu-pipeline-app --kube-context mongo-dcu-pipeline-qa -n qa
helm rollback mongo-dcu-pipeline-app 1 --kube-context mongo-dcu-pipeline-qa -n qa --wait --timeout 5m
```

`<revision>` is the last `deployed` revision in the history - read it, do not
assume it is `1`. A rollback is itself a new revision: after rolling back to 1
from a failed 2, the history reads 1 `superseded`, 2 `failed`, 3 `deployed`.

### Uninstall

Before `terraform destroy`. The chart creates nothing outside the cluster, so
uninstalling is not required for the destroy to succeed - it is the clean
order, and it lets the application stop between files instead of being killed
with its node.

```bash
# variable form
helm uninstall $RELEASE --kube-context $CLUSTER_NAME -n $ENV --wait

# expanded
helm uninstall mongo-dcu-pipeline-app --kube-context mongo-dcu-pipeline-qa -n qa --wait
```

## When something is wrong

| Symptom | First thing to check |
|---|---|
| `helm template` fails with `... is required` | The generated values file was not passed, or is from before an apply. Rerun `ansible-playbook playbooks/render-values.yml -e target_env=$ENV` |
| `violates PodSecurity "restricted"` on install | A security context value was overridden. The server-side dry run above shows this without installing |
| Pod `CrashLoopBackOff`, log ends in `startup failed` | The startup connectivity checks. Run `ansible-playbook playbooks/smoke-tests.yml` - it checks the same paths and names the one that is broken |
| Pod Running, log stops after `starting`, no error | An AWS call hanging. `AWS_DEFAULT_REGION` missing, or a VPC endpoint missing ([issue 17](ISSUES.md)) |
| `ImagePullBackOff` | The tag. `aws ecr describe-images --repository-name $PROJECT-app` lists what exists |
| Upgrade applied, behaviour unchanged | The ConfigMap changed but the pod did not restart - check the `checksum/config` annotation changed between revisions |
