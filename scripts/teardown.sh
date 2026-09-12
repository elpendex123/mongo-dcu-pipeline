#!/usr/bin/env bash
# The enforced end-of-session sequence:
#
#   status -> terraform destroy (qa, prod, data tier) -> status -> nuke -> status
#
# The order is the point. A destroy and a nuke run out of order, or a nuke run
# without checking what is left first, is how a resource survives teardown
# unnoticed and bills for a month. Running this is one action; running the
# pieces by hand is four chances to stop halfway.
#
# The permanent shared stack - the registry and the analytics bucket - is not
# touched. It costs a few cents a month and every environment is rebuilt from
# the image it holds.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_common_flags "$@"

SKIP_NUKE=false
for arg in "$@"; do
  [[ "$arg" == "--no-nuke" ]] && SKIP_NUKE=true
done

if [[ "${SHOW_HELP:-false}" == "true" ]]; then
  echo "usage: $(basename "$0") [--yes] [--no-nuke]"
  echo
  echo "  Destroys qa, prod and the data tier, then sweeps for anything left."
  echo "  --no-nuke   Stop after terraform destroy and a status report."
  echo
  echo "  Leaves alone: the state bucket, the ECR repository, the analytics"
  echo "  bucket, and the dev buckets (use dev-s3-destroy.sh for those)."
  exit 0
fi

require_tools terraform aws jq

# Environments destroyed in dependency order. qa and prod own the peering
# connections into the data tier, so they go first - destroying the data tier
# while a peering connection into it still exists leaves the VPC undeletable.
STACKS=(qa prod shared-data)

head1 "1/5  status before teardown"
"$REPO_ROOT/scripts/status.sh" | sed -n '/^cost/,$p'

confirm "Destroy qa, prod and the data tier?"

head1 "2/5  terraform destroy"
for stack in "${STACKS[@]}"; do
  dir="$REPO_ROOT/terraform/environments/$stack"
  if [[ ! -f "$dir/main.tf" ]]; then
    echo "  ${C_DIM}$stack - not built yet, skipping${C_RESET}"
    continue
  fi
  info "destroying $stack"
  if terraform -chdir="$dir" init -input=false >/dev/null 2>&1 \
     && terraform -chdir="$dir" destroy -input=false -auto-approve; then
    ok "$stack destroyed"
  else
    # Deliberately not fatal. A stack that fails to destroy is exactly the case
    # the nuke step exists for, and stopping here would skip it.
    warn "$stack destroy failed - the nuke step below is what handles this"
  fi
done

head1 "3/5  status after destroy"
"$REPO_ROOT/scripts/status.sh" | sed -n '/^cost/,$p'

if [[ "$SKIP_NUKE" == "true" ]]; then
  warn "stopping before the nuke step (--no-nuke)"
  exit 0
fi

head1 "4/5  nuke - anything terraform destroy missed"
"$REPO_ROOT/scripts/nuke.sh" --dry-run --skip-dev
echo
if [[ "${ASSUME_YES:-false}" == "true" ]]; then
  "$REPO_ROOT/scripts/nuke.sh" --yes --skip-dev
else
  "$REPO_ROOT/scripts/nuke.sh" --skip-dev
fi

head1 "5/5  final status"
"$REPO_ROOT/scripts/status.sh"
