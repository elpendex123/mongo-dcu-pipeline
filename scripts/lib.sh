#!/usr/bin/env bash
# Shared settings and helpers for the project's shell tooling.
# Sourced, never executed directly.

PROJECT="${PROJECT:-mongo-dcu-pipeline}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# The five buckets every environment gets, in pipeline order.
BUCKET_ROLES=(input successful failed reports-json reports-log)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
