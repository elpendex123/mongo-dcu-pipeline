#!/usr/bin/env bash
# Copies the images kube-prometheus-stack needs into the project's ECR mirror.
#
# The clusters have no route to the internet, so quay.io, registry.k8s.io and
# Docker Hub are unreachable from a node. This copies each image, from here
# where the internet is, to
#
#   <account>.dkr.ecr.<region>.amazonaws.com/mongo-dcu-pipeline-mirror/<upstream path>:<tag>
#
# which is exactly where the chart's global.imageRegistry points.
#
# The copy is registry to registry, with crane, and never passes through
# Docker's local image store. Pulling, tagging and pushing through that store
# failed for kube-state-metrics in three different ways: an upstream Docker v2
# manifest list recorded without its platforms, then layers already present from
# other images kept only as unpacked snapshots with nothing to push (issue 24).
# crane streams the linux/amd64 manifest and its blobs straight across.
#
# The image list is not kept by hand. It is read from the chart itself -
# rendered with the project's own values and the upstream registries - so a
# chart upgrade that adds or renames an image shows up here as "missing" rather
# than in the cluster as ImagePullBackOff.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_common_flags "$@"

MODE=copy
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) MODE=dry-run ;;
    --check)      MODE=check ;;
  esac
done

if [[ "${SHOW_HELP:-false}" == "true" ]]; then
  echo "usage: $(basename "$0") [--dry-run | --check]"
  echo
  echo "  Copies every image kube-prometheus-stack needs into ECR, skipping those already there."
  echo "  --dry-run   List the images and which are mirrored. Pulls and pushes nothing."
  echo "  --check     The same, and exit 1 if any is missing (used by deploy-monitoring.yml)."
  echo
  echo "  Chart version: monitoring_chart_version in ansible/inventory/group_vars/all.yml."
  echo "  Repositories:  mirrored_repositories in terraform/environments/shared."
  exit 0
fi

require_tools helm aws
[[ "$MODE" == "copy" ]] && require_tools docker

# crane, run as a container so nothing has to be installed. Pinned by digest:
# this image handles an ECR password, so it is not left to a moving tag. The
# debug variant carries a shell, which the copy loop below needs.
CRANE_IMAGE="gcr.io/go-containerregistry/crane:debug@sha256:e78770b31258a3846f878036d9c1f63fbe4c871f9f56990bf77fd95c013e3c1b"

GROUP_VARS="$REPO_ROOT/ansible/inventory/group_vars/all.yml"
CHART="$(sed -n 's/^monitoring_chart: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$GROUP_VARS")"
CHART_VERSION="$(sed -n 's/^monitoring_chart_version: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$GROUP_VARS")"
[[ -n "$CHART" && -n "$CHART_VERSION" ]] || die "monitoring_chart and monitoring_chart_version must be set in $GROUP_VARS"

ACCOUNT="$(aws_account_id)"
REGISTRY="$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"
PREFIX="$PROJECT-mirror"

head1 "mirror for $CHART $CHART_VERSION"

# Upstream references, from the chart rendered the way it will be installed but
# with the registry override emptied.
if ! rendered="$(helm template mirror-list "$CHART" --version "$CHART_VERSION" -n monitoring \
      -f "$REPO_ROOT/helm/monitoring/values.yaml" --set global.imageRegistry= 2>&1)"; then
  echo "$rendered" | tail -n 3 >&2
  die "could not render $CHART $CHART_VERSION - is the repository added? ansible-playbook playbooks/helm-repos.yml"
fi

mapfile -t IMAGES < <(
  printf '%s\n' "$rendered" \
    | grep -E '^\s+image:|--prometheus-config-reloader=' \
    | sed -E 's/.*image: *//; s/.*--prometheus-config-reloader=//' \
    | tr -d "\"'" | sed '/^\s*$/d' | sort -u
)
[[ ${#IMAGES[@]} -gt 0 ]] || die "the rendered chart names no images - the extraction above no longer matches the chart"

MISSING_REPOS=()
MISSING_IMAGES=()

printf '  %-9s %-58s %s\n' "state" "repository" "tag"
for ref in "${IMAGES[@]}"; do
  rest="${ref#*/}"            # drop the registry host
  repo="${rest%:*}"
  tag="${rest##*:}"
  if ! aws ecr describe-repositories --repository-names "$PREFIX/$repo" --region "$AWS_REGION" >/dev/null 2>&1; then
    printf '  %s%-9s%s %-58s %s\n' "$C_RED" "no repo" "$C_RESET" "$repo" "$tag"
    MISSING_REPOS+=("$repo")
  elif aws ecr describe-images --repository-name "$PREFIX/$repo" --image-ids "imageTag=$tag" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
    printf '  %s%-9s%s %-58s %s\n' "$C_GREEN" "mirrored" "$C_RESET" "$repo" "$tag"
  else
    printf '  %s%-9s%s %-58s %s\n' "$C_YELLOW" "missing" "$C_RESET" "$repo" "$tag"
    MISSING_IMAGES+=("$ref")
  fi
done

echo
if [[ ${#MISSING_REPOS[@]} -gt 0 ]]; then
  err "no ECR repository for: ${MISSING_REPOS[*]}"
  err "add them to mirrored_repositories in terraform/environments/shared and apply that stack"
  exit 1
fi

if [[ ${#MISSING_IMAGES[@]} -eq 0 ]]; then
  ok "all ${#IMAGES[@]} images are mirrored"
  exit 0
fi

case "$MODE" in
  check)
    err "${#MISSING_IMAGES[@]} of ${#IMAGES[@]} images missing from the mirror - run scripts/mirror-images.sh"
    exit 1 ;;
  dry-run)
    ok "dry run - ${#MISSING_IMAGES[@]} of ${#IMAGES[@]} images would be copied"
    exit 0 ;;
esac

# One container for every copy. Its stdin carries the ECR password on the first
# line and a "source destination" pair per image after it - the password never
# appears as an argument or an environment variable, where `ps` or
# `docker inspect` would show it, and dies with the container.
#
# linux/amd64 only: the nodes are t3.small, and mirroring one platform keeps the
# mirror from storing layers for architectures nothing here will ever run.
info "copying ${#MISSING_IMAGES[@]} image(s) with crane"
# Inside an if, so a failed copy reaches the message below. As a bare pipeline
# under set -e and pipefail, the script would exit on the failure first.
if ! {
  aws ecr get-login-password --region "$AWS_REGION"
  for ref in "${MISSING_IMAGES[@]}"; do
    printf '%s %s\n' "$ref" "$REGISTRY/$PREFIX/${ref#*/}"
  done
} | docker run -i --rm --entrypoint /busybox/sh "$CRANE_IMAGE" -c '
    read -r password
    printf "%s" "$password" | crane auth login "'"$REGISTRY"'" -u AWS --password-stdin >/dev/null 2>&1 \
      || { echo "crane could not log in to the registry" >&2; exit 1; }
    while read -r source destination; do
      crane copy --platform linux/amd64 "$source" "$destination" 2>/dev/null \
        || { echo "FAILED $source" >&2; exit 1; }
      echo "copied $destination"
    done
  ' | while read -r line; do ok "$line"; done; then
  die "the copy failed - rerun the script; images already copied are skipped"
fi

echo
ok "copied ${#MISSING_IMAGES[@]} image(s); ${#IMAGES[@]} of ${#IMAGES[@]} now mirrored"
