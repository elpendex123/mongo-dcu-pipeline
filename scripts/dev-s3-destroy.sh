#!/usr/bin/env bash
# Destroys the dev S3 buckets through Terraform.
#
# This is the ordinary teardown path and leaves Terraform state consistent.
# Use dev-s3-nuke.sh only when this fails or when state has been lost.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_common_flags "$@"

if [[ "${SHOW_HELP:-false}" == "true" ]]; then
  echo "usage: $(basename "$0") [--yes]"
  echo "  Runs terraform destroy against terraform/environments/dev."
  exit 0
fi

require_tools terraform aws
STACK="$REPO_ROOT/terraform/environments/dev"

info "account $(aws_account_id), region $AWS_REGION"

head1 "buckets that will be destroyed"
env_buckets dev | sed 's/^/  /'

confirm "Destroy the five dev buckets and everything in them?"

cd "$STACK"
terraform init -input=false >/dev/null
terraform destroy -input=false ${ASSUME_YES:+-auto-approve}

echo
ok "dev S3 destroyed - confirm with scripts/dev-s3-status.sh"
