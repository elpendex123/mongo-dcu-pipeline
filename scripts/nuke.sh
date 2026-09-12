#!/usr/bin/env bash
# Force-deletes every mongo-dcu-pipeline resource directly through the AWS API,
# with no reference to Terraform state.
#
# This is the backstop, not the ordinary path. `terraform destroy` is what to
# run when state is intact; this is for when it is not - a partial apply, a
# lost state file, a resource deleted by hand, a destroy that failed halfway
# and left a VPC that will not delete because something is still attached.
#
# PROTECTED, and never touched (see lib.sh):
#   - the Terraform state bucket. Deleting it does not remove the resources it
#     describes, it removes the only record that they exist.
#   - the ECR repository and the analytics bucket - the permanent shared stack.
#
# Deletion order follows dependencies: compute before the databases it talks
# to, endpoints and peering before the VPC that contains them, and the network
# last, because nothing in a VPC can be deleted while something is attached.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_common_flags "$@"

DRY_RUN=false
SKIP_DEV=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" || "$arg" == "-n" ]] && DRY_RUN=true
  [[ "$arg" == "--skip-dev" ]] && SKIP_DEV=true
done

# dev is swept by default, so that one command can clean the whole account -
# but a session teardown of the AWS environments passes --skip-dev, because
# dev's buckets are what the local Docker Compose stack points at and deleting
# them is a local-development decision, not a consequence of tearing down qa.
SWEEP_ENVIRONMENTS=("${ENVIRONMENTS[@]}")

if [[ "${SHOW_HELP:-false}" == "true" ]]; then
  echo "usage: $(basename "$0") [--dry-run] [--yes] [--skip-dev]"
  echo
  echo "  --dry-run, -n   List what would be deleted and stop. Deletes nothing."
  echo "  --yes, -y       Skip the confirmation prompt."
  echo "  --skip-dev      Leave the dev buckets alone - they belong to the"
  echo "                  local stack, not to an AWS environment."
  echo
  echo "  Force-deletes everything tagged project=$PROJECT, except the state"
  echo "  bucket, the ECR repository and the analytics bucket."
  echo
  echo "  Run --dry-run first. Always."
  exit 0
fi

require_tools aws jq

ACCOUNT="$(aws_account_id)"
head1 "mongo-dcu-pipeline nuke  (account $ACCOUNT, region $AWS_REGION)"

echo "  ${C_YELLOW}protected, will not be touched:${C_RESET}"
protected_names "$ACCOUNT" | sed 's/^/    /'

# Waits for a resource to disappear, printing progress. Deletions here take
# minutes, and a script that returns before the resource is gone will fail on
# the next step for a reason that looks unrelated.
wait_gone() {
  local what="$1" check="$2" timeout="${3:-1200}" waited=0
  while eval "$check" >/dev/null 2>&1; do
    if [[ $waited -ge $timeout ]]; then
      err "timed out after ${timeout}s waiting for $what"
      return 1
    fi
    printf '\r    waiting for %s ... %ds' "$what" "$waited"
    sleep 15
    waited=$((waited + 15))
  done
  [[ $waited -gt 0 ]] && printf '\r%*s\r' 60 ''
  ok "gone: $what"
}

# ------------------------------------------------------------------ discovery
head1 "discovery"

EKS_CLUSTERS=$(aws eks list-clusters --region "$AWS_REGION" --query 'clusters' --output json 2>/dev/null \
  | jq -r '.[] | select(startswith("'"$PROJECT"'"))' || true)
DOCDB_CLUSTERS=$(aws docdb describe-db-clusters --region "$AWS_REGION" --output json 2>/dev/null \
  | jq -r '.DBClusters[]? | select(.DBClusterIdentifier | startswith("'"$PROJECT"'")) | .DBClusterIdentifier' || true)
RDS_INSTANCES=$(aws rds describe-db-instances --region "$AWS_REGION" --output json 2>/dev/null \
  | jq -r '.DBInstances[]? | select(.DBInstanceIdentifier | startswith("'"$PROJECT"'")) | .DBInstanceIdentifier' || true)
VPCS=$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters "Name=tag:project,Values=$PROJECT" \
  --query 'Vpcs[].VpcId' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' || true)
SECRETS=$(aws secretsmanager list-secrets --region "$AWS_REGION" --output json 2>/dev/null \
  | jq -r '.SecretList[]? | select(.Name | startswith("'"$PROJECT"'")) | select(.DeletedDate | not) | .Name' || true)

if [[ "$SKIP_DEV" == "true" ]]; then
  SWEEP_ENVIRONMENTS=()
  for e in "${ENVIRONMENTS[@]}"; do [[ "$e" == "dev" ]] || SWEEP_ENVIRONMENTS+=("$e"); done
  echo "  ${C_DIM}skipping dev buckets (--skip-dev) - use dev-s3-nuke.sh for those${C_RESET}"
fi

BUCKETS=()
for env in "${SWEEP_ENVIRONMENTS[@]}"; do
  for role in "${BUCKET_ROLES[@]}"; do
    b="$PROJECT-$env-$role-$ACCOUNT"
    is_protected "$b" "$ACCOUNT" && continue
    bucket_exists "$b" && BUCKETS+=("$b")
  done
done

show() { local label="$1"; shift; local v="$*"; [[ -n "${v// }" ]] && printf '  %-22s %s\n' "$label" "$(echo "$v" | tr '\n' ' ')" || true; }
show "EKS clusters"    "$EKS_CLUSTERS"
show "DocumentDB"      "$DOCDB_CLUSTERS"
show "RDS instances"   "$RDS_INSTANCES"
show "VPCs"            "$VPCS"
show "secrets"         "$SECRETS"
show "S3 buckets"      "${BUCKETS[*]:-}"

# grep -c exits 1 when it counts zero, which under `set -e` would kill the
# script in the middle of the arithmetic that is asking "is there anything to
# do?" - the one question it must be able to answer when the answer is no.
count_lines() { local v="${1:-}"; [[ -z "${v// }" ]] && { echo 0; return; }; printf '%s\n' "$v" | sed '/^$/d' | wc -l; }

TOTAL=$(( $(count_lines "${EKS_CLUSTERS:-}") + $(count_lines "${DOCDB_CLUSTERS:-}") \
        + $(count_lines "${RDS_INSTANCES:-}") + $(count_lines "${VPCS:-}") \
        + $(count_lines "${SECRETS:-}") + ${#BUCKETS[@]} ))
if [[ "$TOTAL" -eq 0 ]]; then
  ok "nothing to delete - no unprotected project resources exist"
  exit 0
fi

# Stops here on purpose, before anything is armed. A script that can only be
# understood by running it is a script that gets run to find out what it does.
if [[ "$DRY_RUN" == "true" ]]; then
  echo
  ok "dry run - nothing deleted. $TOTAL resource group(s) would be removed."
  echo "  Re-run without --dry-run to delete them."
  exit 0
fi

confirm "Permanently delete the $TOTAL resource group(s) listed above?"

# ----------------------------------------------------------------------- EKS
if [[ -n "$EKS_CLUSTERS" ]]; then
  head1 "EKS"
  while read -r c; do
    [[ -z "$c" ]] && continue
    for ng in $(aws eks list-nodegroups --cluster-name "$c" --region "$AWS_REGION" --query 'nodegroups' --output text 2>/dev/null); do
      info "deleting node group $ng"
      aws eks delete-nodegroup --cluster-name "$c" --nodegroup-name "$ng" --region "$AWS_REGION" >/dev/null
      wait_gone "node group $ng" "aws eks describe-nodegroup --cluster-name $c --nodegroup-name $ng --region $AWS_REGION"
    done
    info "deleting cluster $c"
    aws eks delete-cluster --name "$c" --region "$AWS_REGION" >/dev/null
    wait_gone "cluster $c" "aws eks describe-cluster --name $c --region $AWS_REGION"
  done <<<"$EKS_CLUSTERS"
fi

# ---------------------------------------------------------------- DocumentDB
if [[ -n "$DOCDB_CLUSTERS" ]]; then
  head1 "DocumentDB"
  while read -r c; do
    [[ -z "$c" ]] && continue
    for i in $(aws docdb describe-db-instances --region "$AWS_REGION" --output json \
                | jq -r '.DBInstances[]? | select(.DBClusterIdentifier == "'"$c"'") | .DBInstanceIdentifier'); do
      info "deleting instance $i"
      aws docdb delete-db-instance --db-instance-identifier "$i" --region "$AWS_REGION" >/dev/null
      wait_gone "instance $i" "aws docdb describe-db-instances --db-instance-identifier $i --region $AWS_REGION"
    done
    info "deleting cluster $c"
    aws docdb delete-db-cluster --db-cluster-identifier "$c" --region "$AWS_REGION" --skip-final-snapshot >/dev/null
    wait_gone "cluster $c" "aws docdb describe-db-clusters --db-cluster-identifier $c --region $AWS_REGION"
  done <<<"$DOCDB_CLUSTERS"

  # Matched on the -docdb- infix, not just the project prefix. DocumentDB and
  # RDS share one underlying API: `aws docdb describe-db-subnet-groups` returns
  # the RDS instance's subnet group too, and this section runs before the RDS
  # instance is deleted - so a prefix match would try to delete a group still
  # in use and report a failure that means nothing.
  for g in $(aws docdb describe-db-subnet-groups --region "$AWS_REGION" --output json 2>/dev/null \
              | jq -r '.DBSubnetGroups[]? | select(.DBSubnetGroupName | startswith("'"$PROJECT"'-docdb")) | .DBSubnetGroupName'); do
    aws docdb delete-db-subnet-group --db-subnet-group-name "$g" --region "$AWS_REGION" >/dev/null 2>&1 \
      && ok "deleted subnet group $g" || warn "could not delete subnet group $g"
  done
fi

# ----------------------------------------------------------------------- RDS
if [[ -n "$RDS_INSTANCES" ]]; then
  head1 "RDS"
  while read -r i; do
    [[ -z "$i" ]] && continue
    info "deleting instance $i"
    # Deletion protection has to come off first, and a final snapshot is
    # deliberately skipped: this is pipeline metadata, regenerable by rerunning.
    aws rds modify-db-instance --db-instance-identifier "$i" --region "$AWS_REGION" \
      --no-deletion-protection --apply-immediately >/dev/null 2>&1 || true
    aws rds delete-db-instance --db-instance-identifier "$i" --region "$AWS_REGION" \
      --skip-final-snapshot --delete-automated-backups >/dev/null
    wait_gone "instance $i" "aws rds describe-db-instances --db-instance-identifier $i --region $AWS_REGION"
  done <<<"$RDS_INSTANCES"

  for g in $(aws rds describe-db-subnet-groups --region "$AWS_REGION" --output json 2>/dev/null \
              | jq -r '.DBSubnetGroups[]? | select(.DBSubnetGroupName | startswith("'"$PROJECT"'"))
                       | select(.DBSubnetGroupName | contains("-docdb-") | not) | .DBSubnetGroupName'); do
    aws rds delete-db-subnet-group --db-subnet-group-name "$g" --region "$AWS_REGION" >/dev/null 2>&1 \
      && ok "deleted subnet group $g" || warn "could not delete subnet group $g"
  done
fi

# ------------------------------------------------------------ Secrets Manager
if [[ -n "$SECRETS" ]]; then
  head1 "Secrets Manager"
  while read -r s; do
    [[ -z "$s" ]] && continue
    # Without --force-delete-without-recovery the secret sits in a 30-day
    # recovery window, still billing, and the name cannot be reused - so the
    # next apply fails on a name that looks free.
    aws secretsmanager delete-secret --secret-id "$s" --region "$AWS_REGION" \
      --force-delete-without-recovery >/dev/null && ok "deleted $s"
  done <<<"$SECRETS"
fi

# ----------------------------------------------------------- VPCs and network
if [[ -n "$VPCS" ]]; then
  head1 "VPC"
  while read -r v; do
    [[ -z "$v" ]] && continue
    info "tearing down $v"

    for pcx in $(aws ec2 describe-vpc-peering-connections --region "$AWS_REGION" \
        --filters "Name=requester-vpc-info.vpc-id,Values=$v" --output json \
        | jq -r '.VpcPeeringConnections[]? | select(.Status.Code != "deleted") | .VpcPeeringConnectionId'); do
      aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$pcx" --region "$AWS_REGION" >/dev/null \
        && ok "deleted peering $pcx"
    done

    eps=$(aws ec2 describe-vpc-endpoints --region "$AWS_REGION" --filters "Name=vpc-id,Values=$v" \
      --query 'VpcEndpoints[].VpcEndpointId' --output text | tr '\t' ' ')
    if [[ -n "${eps// }" ]]; then
      # shellcheck disable=SC2086
      aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $eps --region "$AWS_REGION" >/dev/null
      ok "deleted endpoints: $eps"
      sleep 20   # the ENIs behind them take a moment to release
    fi

    for eni in $(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$v" "Name=status,Values=available" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
      aws ec2 delete-network-interface --network-interface-id "$eni" --region "$AWS_REGION" >/dev/null 2>&1 \
        && ok "deleted interface $eni" || true
    done

    for igw in $(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
        --filters "Name=attachment.vpc-id,Values=$v" --query 'InternetGateways[].InternetGatewayId' --output text); do
      aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$v" --region "$AWS_REGION" >/dev/null 2>&1 || true
      aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$AWS_REGION" >/dev/null 2>&1 \
        && ok "deleted gateway $igw" || true
    done

    for sn in $(aws ec2 describe-subnets --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$v" --query 'Subnets[].SubnetId' --output text); do
      aws ec2 delete-subnet --subnet-id "$sn" --region "$AWS_REGION" >/dev/null 2>&1 \
        && ok "deleted subnet $sn" || warn "could not delete subnet $sn"
    done

    # The main route table and the default security group go with the VPC and
    # cannot be deleted on their own.
    for rt in $(aws ec2 describe-route-tables --region "$AWS_REGION" --filters "Name=vpc-id,Values=$v" \
        --output json | jq -r '.RouteTables[]? | select([.Associations[]?.Main] | any | not) | .RouteTableId'); do
      aws ec2 delete-route-table --route-table-id "$rt" --region "$AWS_REGION" >/dev/null 2>&1 \
        && ok "deleted route table $rt" || true
    done

    for sg in $(aws ec2 describe-security-groups --region "$AWS_REGION" --filters "Name=vpc-id,Values=$v" \
        --output json | jq -r '.SecurityGroups[]? | select(.GroupName != "default") | .GroupId'); do
      aws ec2 delete-security-group --group-id "$sg" --region "$AWS_REGION" >/dev/null 2>&1 \
        && ok "deleted security group $sg" || warn "could not delete security group $sg"
    done

    aws ec2 delete-vpc --vpc-id "$v" --region "$AWS_REGION" >/dev/null 2>&1 \
      && ok "deleted VPC $v" || err "could not delete VPC $v - something is still attached"
  done <<<"$VPCS"
fi

# ------------------------------------------------------------------ S3
if [[ ${#BUCKETS[@]} -gt 0 ]]; then
  head1 "S3"
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
  for b in "${BUCKETS[@]}"; do
    is_protected "$b" "$ACCOUNT" && { warn "refusing to delete protected bucket $b"; continue; }
    info "emptying $b"
    ok "removed $(empty_bucket "$b") object version(s)"
    aws s3api delete-bucket --bucket "$b" >/dev/null && ok "deleted $b"
  done
fi

# --------------------------------------------------------------------- IAM
head1 "IAM"
for r in $(aws iam list-roles --query "Roles[?starts_with(RoleName, '$PROJECT')].RoleName" --output text | tr '\t' '\n'); do
  [[ -z "$r" ]] && continue
  for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$r" --policy-arn "$p" >/dev/null 2>&1 || true
  done
  for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames' --output text); do
    aws iam delete-role-policy --role-name "$r" --policy-name "$p" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$r" >/dev/null 2>&1 && ok "deleted role $r" || warn "could not delete role $r"
done
for a in $(aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, '$PROJECT')].Arn" --output text | tr '\t' '\n'); do
  [[ -z "$a" ]] && continue
  for v in $(aws iam list-policy-versions --policy-arn "$a" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$a" --version-id "$v" >/dev/null 2>&1 || true
  done
  aws iam delete-policy --policy-arn "$a" >/dev/null 2>&1 && ok "deleted policy $a" || warn "could not delete policy $a"
done

# ---------------------------------------------------------------- verification
head1 "verification"
"$REPO_ROOT/scripts/status.sh" | sed -n '/^cost/,$p'

echo
warn "Terraform state now references resources that no longer exist."
warn "Reconcile with 'terraform apply' in the affected stack, or delete its state key."
