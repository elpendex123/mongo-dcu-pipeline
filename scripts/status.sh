#!/usr/bin/env bash
# The full picture: every resource this project creates, what it costs per
# hour right now, and whether anything expensive has been left running.
#
# Read only. Safe to run at any time, and the first thing to run at the start
# and end of every session.
#
# Discovery is tag-based (project=mongo-dcu-pipeline) wherever the API supports
# it, so a resource is found regardless of which stack created it - and an
# untagged resource is a resource that survives teardown unnoticed and keeps
# billing.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_common_flags "$@"

if [[ "${SHOW_HELP:-false}" == "true" ]]; then
  echo "usage: $(basename "$0")"
  echo "  Reports every mongo-dcu-pipeline resource and the current hourly cost."
  exit 0
fi

require_tools aws jq

ACCOUNT="$(aws_account_id)"
BILLABLE=0        # counts resources that cost money while they exist

head1 "mongo-dcu-pipeline status  (account $ACCOUNT, region $AWS_REGION, $(date -u '+%Y-%m-%d %H:%M UTC'))"

# ---------------------------------------------------------------- S3 buckets
head1 "S3"
printf '%s\n' "${C_DIM}bucket                                                   objects       size${C_RESET}"

s3_row() {
  local bucket="$1" label="${2:-}"
  if ! bucket_exists "$bucket"; then
    printf '%-55s %s\n' "$bucket" "${C_DIM}absent${C_RESET}"
    return
  fi
  # jq rather than a JMESPath --query: an empty bucket returns no Contents key
  # at all, and sum() over a missing key raises instead of returning zero.
  local count size size_h
  read -r count size < <(
    aws s3api list-objects-v2 --bucket "$bucket" --output json |
      jq -r '[(.Contents // [] | length), (.Contents // [] | map(.Size) | add // 0)] | @tsv'
  )
  size_h=$(numfmt --to=iec --suffix=B "${size:-0}" 2>/dev/null || echo "${size:-0}B")
  printf '%-55s %7s %10s %s\n' "$bucket" "$count" "$size_h" "$label"
}

s3_row "$PROJECT-tfstate-$ACCOUNT"           "${C_YELLOW}protected${C_RESET}"
s3_row "$PROJECT-analytics-exports-$ACCOUNT" "${C_YELLOW}protected${C_RESET}"
for env in "${ENVIRONMENTS[@]}"; do
  for role in "${BUCKET_ROLES[@]}"; do
    s3_row "$PROJECT-$env-$role-$ACCOUNT"
  done
done

# ----------------------------------------------------------------------- ECR
head1 "ECR"
if aws ecr describe-repositories --repository-names "$PROJECT-app" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws ecr describe-images --repository-name "$PROJECT-app" --region "$AWS_REGION" --output json \
    | jq -r '
        if (.imageDetails | length) == 0 then "  (repository exists, no images)"
        else ( .imageDetails | sort_by(.imagePushedAt) | reverse | .[]
               | "  " + ((.imageTags // ["<untagged>"]) | join(","))
                      + "  " + (.imagePushedAt | sub("\\..*$"; "") | sub("T"; " "))
                      + "  " + ((.imageSizeInBytes / 1048576 | round | tostring) + " MiB") )
        end'
  echo "  ${C_YELLOW}protected${C_RESET} - the registry is not torn down between sessions"
else
  echo "  ${C_DIM}repository absent${C_RESET}"
fi

# ----------------------------------------------------------------------- EKS
head1 "EKS"
clusters=$(aws eks list-clusters --region "$AWS_REGION" --query 'clusters' --output json 2>/dev/null \
  | jq -r '.[] | select(startswith("'"$PROJECT"'"))' || true)
if [[ -z "$clusters" ]]; then
  echo "  ${C_DIM}no clusters${C_RESET}"
else
  while read -r c; do
    [[ -z "$c" ]] && continue
    st=$(aws eks describe-cluster --name "$c" --region "$AWS_REGION" --query 'cluster.status' --output text)
    ver=$(aws eks describe-cluster --name "$c" --region "$AWS_REGION" --query 'cluster.version' --output text)
    printf '  %-32s %-10s k8s %s   %s$%s/hr%s\n' "$c" "$st" "$ver" "$C_RED" "$RATE_EKS_CLUSTER" "$C_RESET"
    add_cost "$RATE_EKS_CLUSTER"; BILLABLE=$((BILLABLE + 1))

    for ng in $(aws eks list-nodegroups --cluster-name "$c" --region "$AWS_REGION" --query 'nodegroups' --output text 2>/dev/null); do
      read -r size itype < <(aws eks describe-nodegroup --cluster-name "$c" --nodegroup-name "$ng" \
        --region "$AWS_REGION" --query '[nodegroup.scalingConfig.desiredSize, nodegroup.instanceTypes[0]]' --output text)
      printf '    node group %-20s %s x %s\n' "$ng" "$size" "$itype"
      [[ "$itype" == "t3.small" ]] && add_cost "$RATE_NODE_T3_SMALL" "$size"
      BILLABLE=$((BILLABLE + 1))
    done
  done <<<"$clusters"
fi

# ---------------------------------------------------------------- DocumentDB
head1 "DocumentDB"
docdb=$(aws docdb describe-db-clusters --region "$AWS_REGION" --output json 2>/dev/null \
  | jq -r '.DBClusters[]? | select(.DBClusterIdentifier | startswith("'"$PROJECT"'"))
           | select(.Engine == "docdb") | .DBClusterIdentifier' || true)
if [[ -z "$docdb" ]]; then
  echo "  ${C_DIM}no clusters${C_RESET}"
else
  while read -r c; do
    [[ -z "$c" ]] && continue
    st=$(aws docdb describe-db-clusters --db-cluster-identifier "$c" --region "$AWS_REGION" \
      --query 'DBClusters[0].Status' --output text)
    ep=$(aws docdb describe-db-clusters --db-cluster-identifier "$c" --region "$AWS_REGION" \
      --query 'DBClusters[0].Endpoint' --output text)
    printf '  %-32s %s\n    %s\n' "$c" "$st" "$ep"
    while read -r inst cls ist; do
      [[ -z "$inst" ]] && continue
      printf '    %-30s %-16s %s   %s$%s/hr%s\n' "$inst" "$cls" "$ist" "$C_RED" "$RATE_DOCDB_T3_MEDIUM" "$C_RESET"
      [[ "$cls" == "db.t3.medium" ]] && add_cost "$RATE_DOCDB_T3_MEDIUM"
      BILLABLE=$((BILLABLE + 1))
    done < <(aws docdb describe-db-instances --region "$AWS_REGION" --output json \
      | jq -r '.DBInstances[]? | select(.DBClusterIdentifier == "'"$c"'")
               | [.DBInstanceIdentifier, .DBInstanceClass, .DBInstanceStatus] | @tsv')
  done <<<"$docdb"
fi

# ----------------------------------------------------------------------- RDS
head1 "RDS"
# Filtered on the engine, not the name. DocumentDB and RDS share one
# underlying API, so `aws rds describe-db-instances` returns the DocumentDB
# instance as well - which would list it twice and count it as billable twice.
rds=$(aws rds describe-db-instances --region "$AWS_REGION" --output json 2>/dev/null \
  | jq -r '.DBInstances[]? | select(.DBInstanceIdentifier | startswith("'"$PROJECT"'"))
           | select(.Engine | startswith("docdb") | not)
           | [.DBInstanceIdentifier, .DBInstanceClass, .DBInstanceStatus, (.Endpoint.Address // "-"), (.PubliclyAccessible|tostring)] | @tsv' || true)
if [[ -z "$rds" ]]; then
  echo "  ${C_DIM}no instances${C_RESET}"
else
  while IFS=$'\t' read -r id cls st ep pub; do
    [[ -z "$id" ]] && continue
    printf '  %-32s %-14s %-12s %s$%s/hr%s\n' "$id" "$cls" "$st" "$C_RED" "$RATE_RDS_T3_MICRO" "$C_RESET"
    printf '    endpoint %s   public: %s\n' "$ep" "$pub"
    [[ "$cls" == "db.t3.micro" ]] && add_cost "$RATE_RDS_T3_MICRO"
    BILLABLE=$((BILLABLE + 1))
  done <<<"$rds"
fi

# ---------------------------------------------------------- VPC and endpoints
head1 "VPC"
vpcs=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters "Name=tag:project,Values=$PROJECT" --output json 2>/dev/null \
  | jq -r '.Vpcs[]? | [.VpcId, .CidrBlock, ((.Tags[]? | select(.Key=="Name") | .Value) // "-")] | @tsv' || true)
if [[ -z "$vpcs" ]]; then
  echo "  ${C_DIM}no VPCs${C_RESET}"
else
  while IFS=$'\t' read -r vid cidr name; do
    [[ -z "$vid" ]] && continue
    printf '  %-24s %-18s %s\n' "$vid" "$cidr" "$name"

    # Interface endpoints bill per availability zone, so the count that matters
    # is endpoint x subnet, not endpoint.
    while IFS=$'\t' read -r svc etype azs; do
      [[ -z "$svc" ]] && continue
      short="${svc##*.$AWS_REGION.}"
      if [[ "$etype" == "Interface" ]]; then
        printf '    endpoint %-26s %-10s %s AZ   %s$%s/hr%s\n' "$short" "$etype" "$azs" "$C_RED" \
          "$(awk -v r="$RATE_VPC_ENDPOINT" -v n="$azs" 'BEGIN{printf "%.2f", r*n}')" "$C_RESET"
        add_cost "$RATE_VPC_ENDPOINT" "$azs"
        BILLABLE=$((BILLABLE + 1))
      else
        printf '    endpoint %-26s %-10s %sfree%s\n' "$short" "$etype" "$C_GREEN" "$C_RESET"
      fi
    done < <(aws ec2 describe-vpc-endpoints --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=$vid" --output json \
      | jq -r '.VpcEndpoints[]? | [.ServiceName, .VpcEndpointType, (.SubnetIds | length)] | @tsv')

    while IFS=$'\t' read -r pcx st peer; do
      [[ -z "$pcx" ]] && continue
      printf '    peering  %-26s %-10s -> %s  %sfree%s\n' "$pcx" "$st" "$peer" "$C_GREEN" "$C_RESET"
    done < <(aws ec2 describe-vpc-peering-connections --region "$AWS_REGION" \
      --filters "Name=requester-vpc-info.vpc-id,Values=$vid" --output json \
      | jq -r '.VpcPeeringConnections[]? | select(.Status.Code != "deleted")
               | [.VpcPeeringConnectionId, .Status.Code, .AccepterVpcInfo.VpcId] | @tsv')
  done <<<"$vpcs"
fi

# A NAT gateway is never created by this project. If one exists, something went
# wrong, and it is the single most expensive thing that can quietly appear.
nats=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
  --filter "Name=state,Values=available" --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)
if [[ -n "$nats" ]]; then
  warn "NAT gateway(s) present: $nats"
  warn "this project uses VPC endpoints and should never create one - \$$RATE_NAT_GATEWAY/hr each"
  for _ in $nats; do add_cost "$RATE_NAT_GATEWAY"; BILLABLE=$((BILLABLE + 1)); done
fi

# ------------------------------------------------------------ Secrets Manager
head1 "Secrets Manager"
secrets=$(aws secretsmanager list-secrets --region "$AWS_REGION" --output json 2>/dev/null \
  | jq -r '.SecretList[]? | select(.Name | startswith("'"$PROJECT"'"))
           | [.Name, (if .DeletedDate then "PENDING DELETION" else "active" end)] | @tsv' || true)
if [[ -z "$secrets" ]]; then
  echo "  ${C_DIM}no secrets${C_RESET}"
else
  echo "$secrets" | while IFS=$'\t' read -r n st; do printf '  %-52s %s\n' "$n" "$st"; done
  echo "  ${C_DIM}\$0.40 per secret per month, billed whether or not anything is running${C_RESET}"
fi

# ------------------------------------------------------- everything by tag
# Advisory only. The Resource Groups Tagging API is eventually consistent and
# keeps returning ARNs for resources that were deleted minutes or hours ago, so
# this section can show things that no longer exist. The per-service sections
# above query each service directly and are the authoritative answer.
head1 "all resources tagged project=$PROJECT  ${C_DIM}(lags deletions - advisory)${C_RESET}"
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=project,Values=$PROJECT" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null \
  | tr '\t' '\n' | sed '/^$/d' | sort | sed 's/^/  /' | grep . || echo "  (none)"

# ------------------------------------------------------------------ the total
head1 "cost"
hourly="$(cost_so_far)"
printf '  billable resources running: %s\n' "$BILLABLE"
printf '  approximate cost:  %s$%s/hr%s   $%s/day if left up   $%s/month if left up\n' \
  "$C_BOLD" "$hourly" "$C_RESET" \
  "$(awk -v h="$hourly" 'BEGIN{printf "%.2f", h*24}')" \
  "$(awk -v h="$hourly" 'BEGIN{printf "%.0f", h*24*30}')"

if [[ "$BILLABLE" -eq 0 ]]; then
  ok "nothing billable is running"
else
  echo
  warn "$BILLABLE billable resource(s) are up - run scripts/teardown at the end of the session"
fi

echo
echo "  ${C_DIM}Rates are approximate us-east-1 on-demand figures for spotting a forgotten${C_RESET}"
echo "  ${C_DIM}cluster, not a billing source of truth. S3, ECR storage and data transfer${C_RESET}"
echo "  ${C_DIM}are not counted; at this project's volume they are pennies a month.${C_RESET}"
