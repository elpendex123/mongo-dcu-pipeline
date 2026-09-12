# Phase 5 - Container registry

**What this phase built:** the shared Terraform stack - the container registry
and the cross-environment analytics bucket, both outside any environment's
lifecycle - and `scripts/build-push.sh`.

**Cost:** a few cents a month for image storage. The $0.53/hr clock starts in
Phase 6, not here.

## 1. The shared stack is applied and agrees with the code

```bash
# variable form
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared plan

# expanded
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/shared plan
```

Expect `No changes.` Seven resources are managed here: the ECR repository, its
lifecycle policy, and the analytics bucket with its four protection resources.

```bash
terraform -chdir=$PROJECT_ROOT/terraform/environments/shared output
```

```
analytics_bucket    = "mongo-dcu-pipeline-analytics-exports-950639281723"
ecr_registry        = "950639281723.dkr.ecr.us-east-1.amazonaws.com"
ecr_repository_name = "mongo-dcu-pipeline-app"
ecr_repository_url  = "950639281723.dkr.ecr.us-east-1.amazonaws.com/mongo-dcu-pipeline-app"
```

## 2. The repository has the settings it is supposed to have

```bash
# variable form
aws ecr describe-repositories --repository-names $PROJECT-app --region $AWS_REGION \
  --query 'repositories[0].{name:repositoryName,mutability:imageTagMutability,scanOnPush:imageScanningConfiguration.scanOnPush,encryption:encryptionConfiguration.encryptionType}' \
  --output table

# expanded
aws ecr describe-repositories --repository-names mongo-dcu-pipeline-app --region us-east-1 \
  --query 'repositories[0].{name:repositoryName,mutability:imageTagMutability,scanOnPush:imageScanningConfiguration.scanOnPush,encryption:encryptionConfiguration.encryptionType}' \
  --output table
```

Expect `MUTABLE`, `scanOnPush: True`, `AES256`. Mutability is deliberate -
see `docs/ECR.md` for why, and for why it is safe given that only the commit
tag is ever deployed.

The lifecycle policy, and in particular its rule order:

```bash
aws ecr get-lifecycle-policy --repository-name mongo-dcu-pipeline-app \
  --region us-east-1 --query 'lifecyclePolicyText' --output text | jq -c '.rules[]'
```

Rule 1 expires untagged images after a day; rule 2 keeps the 10 most recent.
The untagged rule **must** come first: a `tagStatus: "any"` rule matches
everything after it, so the order is load-bearing rather than cosmetic.

## 3. A build reaches the registry

```bash
# variable form
cd $PROJECT_ROOT && ./scripts/build-push.sh

# expanded
cd ~/Documents/PROJECTS/mongo-dcu-pipeline && ./scripts/build-push.sh
```

Expect a build, a login, two pushes, and a table of what is now in the
repository:

```
images in mongo-dcu-pipeline-app
  TAGS                  PUSHED               SIZE
  latest,13bb58b-dirty  2026-09-11 22:25:39  66.9 MiB

deploy reference
  950639281723.dkr.ecr.us-east-1.amazonaws.com/mongo-dcu-pipeline-app:13bb58b-dirty
```

**A `-dirty` suffix is a feature, not a problem.** It means the working tree
had uncommitted changes, so the image does not correspond to the commit its
tag names. Commit first and rebuild to get a clean tag.

Independently:

```bash
aws ecr list-images --repository-name mongo-dcu-pipeline-app --region us-east-1 --output table
```

## 4. The image was scanned

A minute or two after the push:

```bash
# variable form
aws ecr describe-image-scan-findings --repository-name $PROJECT-app \
  --image-id imageTag=$TAG --region $AWS_REGION \
  --query '{status:imageScanStatus.status,counts:imageScanFindingsSummary.findingSeverityCounts}'

# expanded
aws ecr describe-image-scan-findings --repository-name mongo-dcu-pipeline-app \
  --image-id imageTag=13bb58b-dirty --region us-east-1 \
  --query '{status:imageScanStatus.status,counts:imageScanFindingsSummary.findingSeverityCounts}'
```

Expect `"status": "COMPLETE"` and `"counts": null` - the scan ran and found
nothing.

## 5. The pushed image actually runs

Proves the registry holds a working image, not merely bytes.

```bash
# variable form
docker run --rm $REPO_URI:$TAG python -c "import app.parser, app.validator; print('import ok')"

# expanded
docker run --rm 950639281723.dkr.ecr.us-east-1.amazonaws.com/mongo-dcu-pipeline-app:latest \
  python -c "import app.parser, app.validator; print('import ok')"
```

Then the real entrypoint, with no configuration at all:

```bash
docker run --rm 950639281723.dkr.ecr.us-east-1.amazonaws.com/mongo-dcu-pipeline-app:latest
```

```
FATAL: configuration is invalid:
  - S3_INPUT_BUCKET is required
  ...
  - MYSQL_USER is required
```

Exit code 2, immediately. That is the correct result: the application starts,
validates its own configuration, names every missing value at once rather than
one per restart, and refuses to poll. A container that started successfully
here would be the surprising outcome.

To be certain the image came from the registry rather than the local build
cache, remove the local copy first:

```bash
docker image rm 950639281723.dkr.ecr.us-east-1.amazonaws.com/mongo-dcu-pipeline-app:latest
docker pull   950639281723.dkr.ecr.us-east-1.amazonaws.com/mongo-dcu-pipeline-app:latest
```

## 6. The analytics bucket is protected like every other bucket

```bash
# variable form
aws s3api get-bucket-versioning --bucket $PROJECT-analytics-exports-$ACCOUNT_ID
aws s3api get-bucket-encryption --bucket $PROJECT-analytics-exports-$ACCOUNT_ID
aws s3api get-public-access-block --bucket $PROJECT-analytics-exports-$ACCOUNT_ID

# expanded
aws s3api get-bucket-versioning  --bucket mongo-dcu-pipeline-analytics-exports-950639281723
aws s3api get-bucket-encryption  --bucket mongo-dcu-pipeline-analytics-exports-950639281723
aws s3api get-public-access-block --bucket mongo-dcu-pipeline-analytics-exports-950639281723
```

Expect `Enabled`, `AES256`, and all four public-access flags `true` - the same
four protections `modules/s3` applies, written out here because a single bucket
with no environment in its name does not fit that module's shape.

## 7. The tag query - and the trap in it

```bash
# variable form
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=project,Values=$PROJECT Key=environment,Values=shared \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n'

# expanded
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=project,Values=mongo-dcu-pipeline Key=environment,Values=shared \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n'
```

Expect **three** ARNs, not two:

```
arn:aws:s3:::mongo-dcu-pipeline-analytics-exports-950639281723
arn:aws:s3:::mongo-dcu-pipeline-tfstate-950639281723
arn:aws:ecr:us-east-1:950639281723:repository/mongo-dcu-pipeline-app
```

The Terraform **state bucket** carries the project tag too. That is correct for
discovery and fatal for deletion: `nuke.sh` in Phase 6 is defined as
force-delete everything carrying the project tag, and run naively it would
delete the state for every environment and the image every environment runs.
Issue 8 in `docs/ISSUES.md` records it; Phase 6 carries the exclusion list that
answers it.

## What this phase does not prove

That the cluster can pull the image. Nothing pulls from ECR yet - the node
role, the `ecr.api` and `ecr.dkr` interface endpoints and the S3 gateway
endpoint that layer downloads need are all Phase 6 and Phase 7. This phase
proves only that the image is in the registry and runs.
