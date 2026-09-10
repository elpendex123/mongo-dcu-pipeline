#!/usr/bin/env bash
# Reports on the dev buckets only: existence, object count, total size, and the
# protection settings that are supposed to be on every one of them.
#
# Read only. Safe to run at any time.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools aws jq

ACCOUNT="$(aws_account_id)"
head1 "dev S3 status  (account $ACCOUNT, region $AWS_REGION)"

printf '%s\n' "${C_DIM}bucket                                              objects       size  ver  enc  pab${C_RESET}"

present=0
missing=0

for role in "${BUCKET_ROLES[@]}"; do
  bucket="$PROJECT-dev-$role-$ACCOUNT"

  if ! bucket_exists "$bucket"; then
    printf '%-50s %s\n' "$bucket" "${C_DIM}absent${C_RESET}"
    missing=$((missing + 1))
    continue
  fi
  present=$((present + 1))

  # The CLI paginates list-objects-v2 itself, so Contents holds every key. jq
  # rather than a JMESPath --query because an empty bucket returns no Contents
  # key at all, and sum() over that is an error rather than zero.
  read -r count size < <(
    aws s3api list-objects-v2 --bucket "$bucket" --output json |
      jq -r '[(.Contents // [] | length), (.Contents // [] | map(.Size) | add // 0)] | @tsv'
  )

  ver=$(aws s3api get-bucket-versioning --bucket "$bucket" --query 'Status' --output text 2>/dev/null)
  [[ "$ver" == "Enabled" ]] && ver="yes" || ver="NO "

  if aws s3api get-bucket-encryption --bucket "$bucket" >/dev/null 2>&1; then enc="yes"; else enc="NO "; fi

  pab=$(aws s3api get-public-access-block --bucket "$bucket" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
    --output text 2>/dev/null | tr '\t' '\n' | sort -u | tr -d '\n')
  [[ "$pab" == "True" ]] && pab="yes" || pab="NO "

  size_h=$(numfmt --to=iec --suffix=B "${size:-0}" 2>/dev/null || echo "${size:-0}B")
  printf '%-50s %7s %10s  %s  %s  %s\n' "$bucket" "$count" "$size_h" "$ver" "$enc" "$pab"
done

head1 "summary"
echo "  present: $present   absent: $missing"

if [[ $present -gt 0 ]]; then
  head1 "contents"
  for role in "${BUCKET_ROLES[@]}"; do
    bucket="$PROJECT-dev-$role-$ACCOUNT"
    bucket_exists "$bucket" || continue
    listing=$(aws s3 ls "s3://$bucket" --recursive 2>/dev/null | head -10)
    if [[ -n "$listing" ]]; then
      echo "  ${C_BOLD}$role${C_RESET}"
      echo "$listing" | sed 's/^/    /'
    fi
  done
fi

head1 "tagged resources for environment=dev"
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=project,Values=$PROJECT" "Key=environment,Values=dev" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text \
  | tr '\t' '\n' | sed 's/^/  /' | grep . || echo "  (none)"
