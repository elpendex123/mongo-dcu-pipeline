#!/usr/bin/env bash
# The QA -> prod promotion gate.
#
#   scripts/promote.sh --file samples/all-good.txt --token 9f2c1d7a4b8e6350
#
# Copies one file into prod's input bucket, and only if a qa run of this exact
# file - byte for byte, by SHA-256 - succeeded completely and issued this token,
# the token has not been used, and it has not expired. Any check failing is a
# hard failure with nothing copied, and every failing check is named.
#
# The token is marked used BEFORE the copy, by a conditional UPDATE that must
# change exactly one row, so two promotions racing on one token cannot both get
# through. If the copy then fails, the claim is released.
#
# Runs from the Jenkins host, over MySQL's public endpoint, which admits one
# address - so that address is checked first.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_common_flags "$@"

FILE=""
TOKEN=""
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)    [[ $# -ge 2 ]] || die "--file needs a path"; FILE="$2"; shift 2 ;;
    --token)   [[ $# -ge 2 ]] || die "--token needs a value"; TOKEN="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -y|--yes|-h|--help) shift ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

if [[ "${SHOW_HELP:-false}" == "true" ]]; then
  echo "usage: $(basename "$0") --file PATH --token TOKEN [--dry-run] [--yes]"
  echo
  echo "  Promotes a file that passed qa to prod's input bucket."
  echo "  --dry-run   Run every check, claim nothing, copy nothing."
  echo "  --yes       Skip the confirmation prompt (required without a terminal)."
  echo
  echo "  The token is in the qa run's success email, both of its reports, and"
  echo "  the runs table. It is honoured once, for 24 hours, for that exact file."
  exit 0
fi

[[ -n "$FILE" && -n "$TOKEN" ]] || die "both --file and --token are required (see --help)"
[[ -f "$FILE" ]] || die "no such file: $FILE"
[[ "$TOKEN" =~ ^[0-9a-f]{16}$ ]] || die "token must be 16 lowercase hex characters, as issued - got '$TOKEN'"

require_tools aws jq terraform sha256sum curl

PYTHON="$REPO_ROOT/.venv/bin/python"
[[ -x "$PYTHON" ]] || die "no virtual environment at $REPO_ROOT/.venv - the gate needs its PyMySQL"
gate() { "$PYTHON" "$REPO_ROOT/scripts/promotion_gate.py" "$@"; }

# Hashed and copied from one snapshot, so the file cannot change between the
# check and the copy - the copy is exactly the bytes that were verified.
SNAPSHOT="$(mktemp)"
trap 'rm -f "$SNAPSHOT"' EXIT
cp "$FILE" "$SNAPSHOT"

KEY="$(basename "$FILE")"
FILE_HASH="$(sha256sum "$SNAPSHOT" | awk '{print $1}')"
PROD_INPUT="$(bucket_name prod input)"
DATA_DIR="$REPO_ROOT/terraform/environments/shared-data"

head1 "promote $KEY to prod"
printf '  file    %s\n  sha256  %s\n  token   %s\n  target  s3://%s/%s\n' \
  "$FILE" "$FILE_HASH" "$TOKEN" "$PROD_INPUT" "$KEY"

head1 "1/4  preconditions"
admin_cidr="$(terraform -chdir="$DATA_DIR" output -raw admin_cidr 2>/dev/null)" \
  || die "cannot read the data tier's outputs - is terraform/environments/shared-data applied?"
my_ip="$(curl -s --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]')"
[[ "$admin_cidr" == "$my_ip/32" ]] \
  || die "MySQL admits $admin_cidr but this machine is now $my_ip - reapply terraform/environments/shared-data"
ok "MySQL admits this machine ($admin_cidr)"

bucket_exists "$PROD_INPUT" || die "$PROD_INPUT does not exist - prod is not up. The token was not touched."
ok "prod input bucket exists"

if aws s3api head-object --bucket "$PROD_INPUT" --key "$KEY" >/dev/null 2>&1; then
  die "s3://$PROD_INPUT/$KEY is already waiting to be processed - wait for prod to pick it up. The token was not touched."
fi
ok "nothing named $KEY is waiting in prod"

secret_name="$(terraform -chdir="$DATA_DIR" output -raw rds_secret_name)"
secret="$(aws secretsmanager get-secret-value --secret-id "$secret_name" --region "$AWS_REGION" \
  --query SecretString --output text)"
MYSQL_HOST="$(jq -r .host <<<"$secret")"
MYSQL_PORT="$(jq -r .port <<<"$secret")"
MYSQL_USER="$(jq -r .username <<<"$secret")"
MYSQL_PASSWORD="$(jq -r .password <<<"$secret")"
MYSQL_DATABASE="$(jq -r .database <<<"$secret")"
export MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE
unset secret

head1 "2/4  checks"
if ! gate check "$TOKEN" "$FILE_HASH"; then
  die "promotion refused - nothing was claimed and nothing was copied"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  ok "dry run: every check passed. Nothing claimed, nothing copied."
  exit 0
fi

confirm "Promote $KEY to prod? The token is spent whether or not prod's run succeeds."

head1 "3/4  claim the token"
qa_run="$(gate claim "$TOKEN" "$FILE_HASH")" || die "promotion refused at the claim - nothing was copied"
ok "token claimed - qa run $qa_run"

head1 "4/4  copy to prod"
if aws s3 cp "$SNAPSHOT" "s3://$PROD_INPUT/$KEY" --only-show-errors; then
  ok "s3://$PROD_INPUT/$KEY"
else
  warn "the copy failed - releasing the token so the promotion can be retried"
  if gate release "$TOKEN"; then
    die "nothing was promoted; the token is unused again"
  fi
  die "the copy failed AND the release failed: token $TOKEN is marked used with nothing promoted. Reset it in the runs table by hand."
fi

echo
echo "  prod picks the file up within one polling cycle. Then:"
echo "    aws s3 ls s3://$(bucket_name prod successful)/"
echo "    aws s3 ls s3://$(bucket_name prod failed)/"
