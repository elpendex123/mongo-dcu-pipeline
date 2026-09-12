#!/usr/bin/env bash
# Builds the application image and pushes it to ECR.
#
# Two tags go up for every build:
#
#   <git short sha>  immutable in practice - it names one commit, and it is
#                    what a Helm release should reference, so that what is
#                    deployed can always be traced back to source
#   latest           moving, for convenience at the command line only
#
# If the working tree has uncommitted changes the commit tag gets a `-dirty`
# suffix, because an image tagged with a commit hash that does not describe its
# contents is worse than no tag at all.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TAG=""
PUSH_LATEST=true
PLATFORM="linux/amd64"

usage() {
  cat <<'USAGE'
usage: build-push.sh [--tag TAG] [--no-latest] [--platform PLATFORM]

  --tag TAG            Tag to push. Default: the current git short sha
                       (with a -dirty suffix if the tree is not clean).
  --no-latest          Push only the primary tag, leaving `latest` where it is.
  --platform PLATFORM  Build platform. Default linux/amd64, which is what the
                       t3.small nodes run - a build on an arm64 workstation
                       would otherwise produce an image the cluster cannot run.

The registry is discovered with `aws ecr describe-repositories`, so the shared
Terraform stack must have been applied first.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)      TAG="${2:-}"; shift 2 ;;
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --no-latest) PUSH_LATEST=false; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage >&2; die "unknown argument: $1" ;;
  esac
done

require_tools docker aws git jq

REPO="$PROJECT-app"

# The registry URL comes from the account rather than being assembled from an
# account ID and region here, so there is exactly one definition of it and a
# missing repository fails with an explanation instead of a push to a host that
# does not exist.
REPO_URI="$(aws ecr describe-repositories \
  --repository-names "$REPO" \
  --region "$AWS_REGION" \
  --query 'repositories[0].repositoryUri' \
  --output text 2>/dev/null)" \
  || die "ECR repository '$REPO' not found in $AWS_REGION - apply terraform/environments/shared first"

REGISTRY="${REPO_URI%%/*}"

cd "$REPO_ROOT"

if [[ -z "$TAG" ]]; then
  TAG="$(git rev-parse --short HEAD)"
  if [[ -n "$(git status --porcelain)" ]]; then
    TAG="$TAG-dirty"
    warn "working tree is not clean - tagging $TAG so the image is not passed off as $(git rev-parse --short HEAD)"
  fi
fi

head1 "build and push  (account $(aws_account_id), region $AWS_REGION)"
printf '  repository  %s\n' "$REPO_URI"
printf '  tag         %s\n' "$TAG"
printf '  also latest %s\n' "$PUSH_LATEST"
printf '  platform    %s\n' "$PLATFORM"

# APP_UID is deliberately left at the Dockerfile default here. Compose passes
# the host user's id so a bind-mounted ~/.aws can be read locally; in a cluster
# there are no bind mounts, credentials arrive through IRSA, and an image
# carrying one developer's uid would be a local detail baked into production.
info "building"
docker build \
  --platform "$PLATFORM" \
  --tag "$REPO_URI:$TAG" \
  --label "org.opencontainers.image.source=https://github.com/elpendex123/$PROJECT" \
  --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --file Dockerfile \
  .

if [[ "$PUSH_LATEST" == "true" ]]; then
  docker tag "$REPO_URI:$TAG" "$REPO_URI:latest"
fi

# The password is a 12-hour token piped straight into docker login - it is
# never written to disk or passed as an argument where `ps` would show it.
info "authenticating to $REGISTRY"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
ok "logged in"

info "pushing $REPO_URI:$TAG"
docker push --quiet "$REPO_URI:$TAG"
ok "pushed $TAG"

if [[ "$PUSH_LATEST" == "true" ]]; then
  info "pushing $REPO_URI:latest"
  docker push --quiet "$REPO_URI:latest"
  ok "pushed latest"
fi

head1 "images in $REPO"
aws ecr describe-images --repository-name "$REPO" --region "$AWS_REGION" --output json \
  | jq -r '
      "TAGS\tPUSHED\tSIZE",
      ( .imageDetails
        | sort_by(.imagePushedAt) | reverse
        | .[]
        | [ ((.imageTags // ["<untagged>"]) | join(",")),
            (.imagePushedAt | sub("\\..*$"; "") | sub("T"; " ")),
            ((.imageSizeInBytes / 1048576 * 10 | round / 10 | tostring) + " MiB") ]
        | @tsv )' \
  | column -t -s $'\t' | sed 's/^/  /'

head1 "deploy reference"
echo "  $REPO_URI:$TAG"
echo
echo "  ${C_DIM}Scan on push is enabled; findings take a minute or two to appear:${C_RESET}"
echo "  aws ecr describe-image-scan-findings --repository-name $REPO --image-id imageTag=$TAG --region $AWS_REGION"
