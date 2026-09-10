#!/usr/bin/env bash
# Force-empties and deletes the five dev buckets directly through the AWS API,
# with no reference to Terraform state.
#
# This is the backstop for when `terraform destroy` fails or state has been
# lost. Because the buckets are versioned, emptying them means deleting every
# object version and every delete marker - `aws s3 rm --recursive` removes only
# current versions and leaves the bucket undeletable.
#
# Afterwards the Terraform state for dev still lists buckets that no longer
# exist; run `terraform apply` to reconcile, or remove the state key.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_common_flags "$@"

if [[ "${SHOW_HELP:-false}" == "true" ]]; then
  echo "usage: $(basename "$0") [--yes]"
  echo "  Force-deletes the five dev buckets, independently of Terraform."
  exit 0
fi

require_tools aws jq

ACCOUNT="$(aws_account_id)"
head1 "dev S3 nuke  (account $ACCOUNT, region $AWS_REGION)"

targets=()
for role in "${BUCKET_ROLES[@]}"; do
  bucket="$PROJECT-dev-$role-$ACCOUNT"
  if bucket_exists "$bucket"; then
    targets+=("$bucket")
    echo "  will delete  $bucket"
  else
    echo "  ${C_DIM}absent       $bucket${C_RESET}"
  fi
done

if [[ ${#targets[@]} -eq 0 ]]; then
  ok "nothing to do - no dev buckets exist"
  exit 0
fi

confirm "Permanently delete ${#targets[@]} bucket(s) and every version of every object in them?"

# Deletes every object version and delete marker, one page at a time.
empty_bucket() {
  local bucket="$1" batch removed=0 n
  while true; do
    batch=$(aws s3api list-object-versions --bucket "$bucket" --max-keys 500 \
      --output json --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}')

    n=$(jq '.Objects | if . == null then 0 else length end' <<<"$batch")
    [[ "$n" -eq 0 ]] && break

    aws s3api delete-objects --bucket "$bucket" \
      --delete "$(jq -c '{Objects: .Objects, Quiet: true}' <<<"$batch")" >/dev/null
    removed=$((removed + n))
  done
  echo "$removed"
}

for bucket in "${targets[@]}"; do
  info "emptying $bucket"
  removed="$(empty_bucket "$bucket")"
  ok "removed $removed object version(s)"

  aws s3api delete-bucket --bucket "$bucket"
  ok "deleted $bucket"
done

head1 "verification"
for role in "${BUCKET_ROLES[@]}"; do
  bucket="$PROJECT-dev-$role-$ACCOUNT"
  if bucket_exists "$bucket"; then
    err "still present: $bucket"
  else
    ok "gone: $bucket"
  fi
done

warn "Terraform state for dev may now reference buckets that no longer exist."
warn "Run 'terraform -chdir=terraform/environments/dev apply' to reconcile."
