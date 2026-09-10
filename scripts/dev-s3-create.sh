#!/usr/bin/env bash
# Creates the dev S3 buckets by applying terraform/environments/dev.
#
# dev is S3 only - the application, MongoDB and MySQL run locally under Docker
# Compose. The buckets are real so that file pickup, the copy-then-delete move
# between buckets and report upload are exercised against actual S3 rather than
# a stand-in.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_common_flags "$@"

if [[ "${SHOW_HELP:-false}" == "true" ]]; then
  echo "usage: $(basename "$0") [--yes]"
  echo "  Applies terraform/environments/dev, creating the five dev buckets."
  exit 0
fi

require_tools terraform aws jq
STACK="$REPO_ROOT/terraform/environments/dev"

info "account $(aws_account_id), region $AWS_REGION"
info "applying $STACK"

cd "$STACK"
terraform init -input=false >/dev/null
terraform apply -input=false ${ASSUME_YES:+-auto-approve}

head1 "dev buckets"
terraform output -json bucket_names | jq -r 'to_entries[] | "  \(.key)\t\(.value)"' | column -t -s $'\t'

head1 "environment file lines for local runs"
terraform output -raw env_file_lines

echo
ok "dev S3 ready - check it any time with scripts/dev-s3-status.sh"
