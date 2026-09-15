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

# Upstream images copied in by scripts/mirror-images.sh, for clusters that
# cannot reach a public registry. Part of the permanent shared stack too.
mirrors=$(aws ecr describe-repositories --region "$AWS_REGION" --output json 2>/dev/null \
  | jq -r --arg p "$PROJECT-mirror/" '.repositories[]? | select(.repositoryName | startswith($p)) | .repositoryName' | sort || true)
if [[ -n "$mirrors" ]]; then
  echo "  mirrored upstream images:"
  while read -r r; do
    [[ -z "$r" ]] && continue
    tags=$(aws ecr describe-images --repository-name "$r" --region "$AWS_REGION" --output json 2>/dev/null \
      | jq -r '[.imageDetails[]?.imageTags[]?] | join(",")')
    printf '    %-52s %s\n' "${r#"$PROJECT-mirror/"}" "${tags:-${C_DIM}empty${C_RESET}}"
  done <<<"$mirrors"
fi

# ----------------------------------------------------------------------- EKS
head1 "EKS"
clusters=$(aws eks list-clusters --region "$AWS_REGION" --query 'clusters' --output json 2>/dev/null \
  | jq -r '.[] | select(startswith("'"$PROJECT"'"))' || true)
if [[ -z "$clusters" ]]; then
  echo "  ${C_DIM}no clusters${C_RESET}"
else
  # Compared against each cluster's public API allowlist. A home address
  # changes, and when it does kubectl, Helm and Ansible all time out with
  # nothing in their errors that says why.
  my_ip="$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"

  while read -r c; do
    [[ -z "$c" ]] && continue
    read -r st ver cidrs < <(aws eks describe-cluster --name "$c" --region "$AWS_REGION" --output json \
      | jq -r '[.cluster.status, .cluster.version, ((.cluster.resourcesVpcConfig.publicAccessCidrs // []) | join(","))] | @tsv')
    printf '  %-32s %-10s k8s %s   %s$%s/hr%s\n' "$c" "$st" "$ver" "$C_RED" "$RATE_EKS_CLUSTER" "$C_RESET"
    add_cost "$RATE_EKS_CLUSTER"; BILLABLE=$((BILLABLE + 1))

    printf '    API public access  %s\n' "${cidrs:--}"
    if [[ -n "$my_ip" && ",$cidrs," != *",$my_ip/32,"* && ",$cidrs," != *",0.0.0.0/0,"* ]]; then
      warn "$c admits $cidrs but this machine is now $my_ip - kubectl will time out until the stack is reapplied"
    fi

    for a in $(aws eks list-addons --cluster-name "$c" --region "$AWS_REGION" --query 'addons' --output text 2>/dev/null); do
      read -r av ast < <(aws eks describe-addon --cluster-name "$c" --addon-name "$a" --region "$AWS_REGION" \
        --query '[addon.addonVersion, addon.status]' --output text)
      printf '    add-on %-20s %-24s %s\n' "$a" "$av" "$ast"
    done

    for ng in $(aws eks list-nodegroups --cluster-name "$c" --region "$AWS_REGION" --query 'nodegroups' --output text 2>/dev/null); do
      read -r size itype ngst issues < <(aws eks describe-nodegroup --cluster-name "$c" --nodegroup-name "$ng" \
        --region "$AWS_REGION" --output json \
        | jq -r '[.nodegroup.scalingConfig.desiredSize, (.nodegroup.instanceTypes[0] // "-"), .nodegroup.status, (.nodegroup.health.issues // [] | length)] | @tsv')
      rate="$(node_rate "$itype")"
      printf '    node group %-30s %-9s %s x %s   %s$%s/hr%s\n' "$ng" "$ngst" "$size" "$itype" "$C_RED" \
        "$(awk -v r="${rate:-0}" -v n="$size" 'BEGIN{printf "%.3f", r*n}')" "$C_RESET"
      if [[ -n "$rate" ]]; then
        add_cost "$rate" "$size"
      else
        warn "no rate known for $itype - these nodes are running but not in the total below"
      fi
      # Counted per node, not per node group: two nodes are two billable
      # instances, and the total has to match what can be counted by hand.
      BILLABLE=$((BILLABLE + size))
      if [[ "$issues" -gt 0 ]]; then
        warn "node group $ng reports $issues health issue(s):"
        warn "  aws eks describe-nodegroup --cluster-name $c --nodegroup-name $ng --query nodegroup.health --region $AWS_REGION"
      fi
    done

    # The instances themselves, from EC2 rather than EKS: a node group can say
    # ACTIVE while an instance is still pending, and an instance can outlive a
    # node group that failed to delete cleanly.
    while IFS=$'\t' read -r iid itype2 istate az; do
      [[ -z "$iid" ]] && continue
      printf '      instance %-22s %-10s %-9s %s\n' "$iid" "$itype2" "$istate" "$az"
    done < <(aws ec2 describe-instances --region "$AWS_REGION" \
      --filters "Name=tag:eks:cluster-name,Values=$c" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --output json | jq -r '.Reservations[].Instances[] | [.InstanceId, .InstanceType, .State.Name, .Placement.AvailabilityZone] | @tsv')
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

# ----------------------------------------------------- CloudWatch log groups
# Created by the Container Insights agent, not by Terraform - which is why a
# destroy does not remove them. Storage is cents a month; listed so a group
# with no expiry does not quietly accumulate. nuke.sh deletes them.
head1 "CloudWatch log groups  ${C_DIM}(created by the Container Insights agent, outside Terraform)${C_RESET}"
log_groups=$(aws logs describe-log-groups --region "$AWS_REGION" --log-group-name-prefix "/aws/containerinsights/$PROJECT-" \
  --output json 2>/dev/null | jq -r '.logGroups[]? | [.logGroupName, (.storedBytes // 0)] | @tsv' || true)
if [[ -z "$log_groups" ]]; then
  echo "  ${C_DIM}none${C_RESET}"
else
  while IFS=$'\t' read -r lg bytes; do
    [[ -z "$lg" ]] && continue
    printf '  %-62s %s\n' "$lg" "$(numfmt --to=iec --suffix=B "${bytes:-0}" 2>/dev/null || echo "${bytes}B")"
  done <<<"$log_groups"
fi

# -------------------------------------------------- IAM and launch templates
# Free - none of these bill. Listed because a leftover one has exactly the name
# the next apply wants, and that apply then fails with EntityAlreadyExists.
head1 "IAM and launch templates  ${C_DIM}(free, but a leftover blocks the next apply)${C_RESET}"
iam_roles=$(aws iam list-roles --query "Roles[?starts_with(RoleName, '$PROJECT')].RoleName" --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' || true)
iam_policies=$(aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, '$PROJECT')].PolicyName" --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' || true)
oidc_providers=$(project_oidc_providers)
launch_templates=$(aws ec2 describe-launch-templates --region "$AWS_REGION" \
  --filters "Name=launch-template-name,Values=$PROJECT-*" --query 'LaunchTemplates[].LaunchTemplateName' --output text 2>/dev/null \
  | tr '\t' '\n' | sed '/^$/d' || true)
if [[ -z "$iam_roles$iam_policies$oidc_providers$launch_templates" ]]; then
  echo "  ${C_DIM}none${C_RESET}"
else
  while read -r x; do [[ -n "$x" ]] && printf '  role             %s\n' "$x"; done <<<"$iam_roles"
  while read -r x; do [[ -n "$x" ]] && printf '  policy           %s\n' "$x"; done <<<"$iam_policies"
  while read -r x; do [[ -n "$x" ]] && printf '  OIDC provider    %s\n' "${x#*oidc-provider/}"; done <<<"$oidc_providers"
  while read -r x; do [[ -n "$x" ]] && printf '  launch template  %s\n' "$x"; done <<<"$launch_templates"
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
