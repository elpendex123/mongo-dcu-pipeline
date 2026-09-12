# ECR - the container registry

One repository, `mongo-dcu-pipeline-app`, holding the application image that
both qa and prod run. It lives in the **shared** Terraform stack
(`terraform/environments/shared/`), not in either environment.

## Variables used on this page

```bash
export PROJECT_ROOT=~/Documents/PROJECTS/mongo-dcu-pipeline
export PROJECT=mongo-dcu-pipeline
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

export REPO_URI=$(aws ecr describe-repositories --repository-names $PROJECT-app \
  --region $AWS_REGION --query 'repositories[0].repositoryUri' --output text)
export TAG=$(git -C $PROJECT_ROOT rev-parse --short HEAD)
```

| Variable | Example value | Where it comes from |
|---|---|---|
| `PROJECT_ROOT` | `~/Documents/PROJECTS/mongo-dcu-pipeline` | Wherever you cloned the repository |
| `PROJECT` | `mongo-dcu-pipeline` | Fixed. The project slug, and the value of the `project` tag |
| `AWS_REGION` | `us-east-1` | Fixed for this project |
| `ACCOUNT_ID` | `950639281723` | 12 digits, fixed per AWS account. From `aws sts get-caller-identity` |
| `REPO_URI` | `950639281723.dkr.ecr.us-east-1.amazonaws.com/mongo-dcu-pipeline-app` | **Assembled by AWS** from account, region and repository name. Read it back from the ECR API rather than typing it - that is exactly what `build-push.sh` does |
| `TAG` | `142a514` | **Changes every commit.** Seven hex characters from `git rev-parse --short HEAD`, with a `-dirty` suffix if the tree is unclean |

The ECR login password is also generated on demand - a ~2 KB token valid for
12 hours, different on every call, which is why it is piped straight into
`docker login` and never stored in a variable.

## Why it is shared

qa and prod are created and destroyed repeatedly - that is the working pattern
for this project, and the reason the cost stays near zero. If the registry
lived in the qa stack, `terraform destroy` on qa would delete the image prod
runs, and rebuilding it would become a precondition for every provision. So the
registry, like the analytics bucket, sits in a root module with its own state
key and the tag `environment=shared`.

| Setting | Value | Why |
|---|---|---|
| Name | `mongo-dcu-pipeline-app` | §2.1 naming |
| Tag mutability | `MUTABLE` | Every build pushes a commit tag *and* a moving `latest`; immutable tags would reject the second `latest` push |
| Scan on push | Enabled | Basic scanning is free. Enhanced scanning is an Inspector charge and would be the first always-on cost in the account |
| Encryption | AES256 | The images are public base layers plus this project's source; KMS would add per-request cost for no threat model |
| Lifecycle | Untagged expire after 1 day; keep the 10 most recent | Storage is billed per GB-month, and an image nobody can name is an image nobody will deploy |
| `force_delete` | true | Images are reproducible from any commit in a minute; refusing the destroy would protect nothing |

Lifecycle rules are evaluated in priority order, and a `tagStatus = "any"` rule
matches everything after it - so the untagged rule has to come first or it
would never be reached.

## Tagging scheme

Every build pushes two tags:

| Tag | Moves | Used for |
|---|---|---|
| `<git short sha>` | Never | What a Helm release references. What is deployed traces back to one commit |
| `latest` | Every build | Convenience at the command line only. Never deployed |

If the working tree has uncommitted changes, the commit tag is suffixed
`-dirty` - `13bb58b-dirty`. An image tagged with a commit hash that does not
describe its contents is worse than an image with no tag at all, because it
invites exactly the wrong conclusion during an incident.

## Building and pushing

```bash
# variable form
cd $PROJECT_ROOT
./scripts/build-push.sh                       # tag = current git short sha
./scripts/build-push.sh --tag v1.2.0          # explicit tag
./scripts/build-push.sh --tag rc1 --no-latest # leave `latest` where it is

# expanded
cd ~/Documents/PROJECTS/mongo-dcu-pipeline
./scripts/build-push.sh
```

The script discovers the registry with `aws ecr describe-repositories` rather
than assembling `<account>.dkr.ecr.<region>.amazonaws.com` itself, so there is
one definition of the URL and a missing repository fails with an explanation
instead of a push to a host that does not exist. It builds for `linux/amd64`
explicitly, because the nodes are `t3.small` and a build on an arm64
workstation would otherwise produce an image the cluster cannot run.

It does **not** pass the host user's uid as a build argument. Compose does that
locally so a bind-mounted `~/.aws` can be read; in a cluster there are no bind
mounts, credentials arrive through IRSA, and an image carrying one developer's
uid would be a local detail baked into production.

### By hand

Everything the script does, spelled out - worth running once:

```bash
# variable form
REPO_URI=$(aws ecr describe-repositories --repository-names $PROJECT-app \
  --region $AWS_REGION --query 'repositories[0].repositoryUri' --output text)
TAG=$(git rev-parse --short HEAD)

docker build --platform linux/amd64 -t $REPO_URI:$TAG .
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin ${REPO_URI%%/*}
docker push $REPO_URI:$TAG

# expanded
REPO_URI=950639281723.dkr.ecr.us-east-1.amazonaws.com/mongo-dcu-pipeline-app
TAG=142a514

docker build --platform linux/amd64 -t $REPO_URI:$TAG .
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin 950639281723.dkr.ecr.us-east-1.amazonaws.com
docker push $REPO_URI:$TAG
```

The login password is a 12-hour token piped straight into `docker login`. It is
never written to disk by the script and never appears as a command-line
argument where `ps` would show it. Docker itself stores the resulting
credential in `~/.docker/config.json` unencrypted and says so on every login;
on a workstation that is acceptable, and on a build agent it is what a
credential helper exists to fix.

## Reading what is there

```bash
# variable form
aws ecr list-images --repository-name $PROJECT-app --region $AWS_REGION --output table

aws ecr describe-images --repository-name $PROJECT-app --region $AWS_REGION \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].{tags:imageTags,pushed:imagePushedAt,mb:imageSizeInBytes}'

# expanded
aws ecr list-images --repository-name mongo-dcu-pipeline-app --region us-east-1 --output table
```

Scan findings, once the scan completes a minute or two after a push:

```bash
# variable form
aws ecr describe-image-scan-findings --repository-name $PROJECT-app \
  --image-id imageTag=$TAG --region $AWS_REGION \
  --query '{status:imageScanStatus.status,counts:imageScanFindingsSummary.findingSeverityCounts}'

# expanded
aws ecr describe-image-scan-findings --repository-name mongo-dcu-pipeline-app \
  --image-id imageTag=142a514 --region us-east-1 \
  --query '{status:imageScanStatus.status,counts:imageScanFindingsSummary.findingSeverityCounts}'
```

A `status` of `COMPLETE` with `counts: null` means the scan ran and found
nothing - which is what a freshly built `python:3.12-slim` image should say.

## How the cluster pulls it

Nothing in the cluster logs in with a password. Worth being clear about,
because it is the part that looks like it must need a secret and does not:

- The node group's instance role carries `AmazonEC2ContainerRegistryReadOnly`,
  and the kubelet uses it to pull images.
- The pod itself reaches ECR - and S3, Secrets Manager and CloudWatch - through
  **VPC interface endpoints**, with no NAT gateway and no internet egress
  (§9). Two endpoints are needed, not one: `ecr.api` for the authentication
  and metadata calls, and `ecr.dkr` for the layer downloads. The layers
  themselves come from S3, which is why the free S3 gateway endpoint is also
  required for pulls to work at all.

That wiring is built in Phase 6; this page is the registry half of it.

## Cost

Storage is $0.10 per GB-month. The image is roughly 67 MiB, and the lifecycle
policy caps the repository at ten of them - under a gigabyte at worst, so a few
cents a month. Data transfer within the region is free, which is the whole
reason the pull path goes through VPC endpoints rather than the internet.

The registry is deliberately **not** torn down between sessions.
