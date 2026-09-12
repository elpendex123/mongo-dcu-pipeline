#!/usr/bin/env bash
# Shared settings and helpers for the project's shell tooling.
# Sourced, never executed directly.

PROJECT="${PROJECT:-mongo-dcu-pipeline}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# The five buckets every environment gets, in pipeline order.
BUCKET_ROLES=(input successful failed reports-json reports-log)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The environments that own a set of five buckets each.
ENVIRONMENTS=(dev qa prod)

# Resources that carry the project tag but must NEVER be deleted by nuke.sh.
#
# The Terraform state bucket is tagged project=mongo-dcu-pipeline like
# everything else, which is correct for discovery and fatal for deletion:
# deleting it does not remove the resources it describes, it removes the only
# record that they exist - leaving a cluster and two databases billing with
# nothing left that knows about them. The registry and the analytics bucket
# belong to the permanent shared stack and are rebuilt by nobody.
#
# A discovery query and a deletion query are not the same query.
protected_names() {
  local account="$1"
  printf '%s\n' \
    "$PROJECT-tfstate-$account" \
    "$PROJECT-analytics-exports-$account" \
    "$PROJECT-app"
}

is_protected() {
  local name="$1" account="$2" p
  while read -r p; do
    [[ "$name" == "$p" ]] && return 0
  done < <(protected_names "$account")
  return 1
}

# Approximate us-east-1 on-demand rates, USD per hour. Used only to show what
# the account is costing right now - close enough to make a forgotten cluster
# obvious, not a billing source of truth.
RATE_EKS_CLUSTER=0.10
RATE_NODE_T3_SMALL=0.0208
RATE_DOCDB_T3_MEDIUM=0.077
RATE_RDS_T3_MICRO=0.017
RATE_VPC_ENDPOINT=0.01      # per interface endpoint, per availability zone
RATE_NAT_GATEWAY=0.045      # nothing should ever create one of these

# Adds to the running cost total. Bash has no floats, so the accumulator is
# kept in millicents and divided at the end.
COST_TOTAL_MILLI=0
add_cost() {
  local rate="$1" qty="${2:-1}"
  local milli
  milli=$(awk -v r="$rate" -v q="$qty" 'BEGIN { printf "%d", r * q * 100000 }')
  COST_TOTAL_MILLI=$((COST_TOTAL_MILLI + milli))
}
cost_so_far() { awk -v m="$COST_TOTAL_MILLI" 'BEGIN { printf "%.3f", m / 100000 }'; }

# Colour only when writing to a terminal, so Jenkins console output and piped
# output stay free of escape codes.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

info()  { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()    { printf '%s\n' "${C_GREEN}  ok${C_RESET} $*"; }
warn()  { printf '%s\n' "${C_YELLOW}  !!${C_RESET} $*" >&2; }
err()   { printf '%s\n' "${C_RED} ERR${C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }
head1() { printf '\n%s\n' "${C_BOLD}$*${C_RESET}"; }

require_tools() {
  local missing=()
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing required tool(s): ${missing[*]}"
}

# Fails fast with a clear message rather than letting every later call fail
# with an opaque credentials error.
aws_account_id() {
  aws sts get-caller-identity --query Account --output text 2>/dev/null \
    || die "unable to reach AWS - check credentials (aws sts get-caller-identity)"
}

# Full bucket name for a given environment and role.
#   bucket_name dev input  ->  mongo-dcu-pipeline-dev-input-950639281723
bucket_name() {
  local env="$1" role="$2"
  printf '%s-%s-%s-%s' "$PROJECT" "$env" "$role" "$(aws_account_id)"
}

# All five bucket names for an environment, one per line.
env_buckets() {
  local env="$1" account
  account="$(aws_account_id)"
  local role
  for role in "${BUCKET_ROLES[@]}"; do
    printf '%s-%s-%s-%s\n' "$PROJECT" "$env" "$role" "$account"
  done
}

bucket_exists() {
  aws s3api head-bucket --bucket "$1" >/dev/null 2>&1
}

# Destructive operations prompt unless --yes was passed or the caller is not a
# terminal (Jenkins), where an unanswered prompt would hang the build forever.
confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    warn "$prompt -> auto-confirmed (--yes)"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "$prompt -> refusing to proceed without a terminal; pass --yes to confirm explicitly"
  fi
  local reply
  read -r -p "${C_YELLOW}${prompt}${C_RESET} [type 'yes' to continue] " reply
  [[ "$reply" == "yes" ]] || die "aborted"
}

parse_common_flags() {
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) ASSUME_YES=true ;;
      -h|--help) SHOW_HELP=true ;;
    esac
  done
}
