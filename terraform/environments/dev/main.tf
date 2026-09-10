# dev environment.
#
# S3 only. The application itself, MongoDB and MySQL all run locally under
# Docker Compose, but the buckets are real: file pickup, the copy-then-delete
# move between buckets and report upload are exercised against actual S3 from
# the first local run rather than against a stand-in that behaves differently.
#
# Storage for a handful of small text files costs a fraction of a cent per
# month, so there is nothing to gain from faking it.

data "aws_caller_identity" "current" {}

module "buckets" {
  source = "../../modules/s3"

  project     = var.project
  environment = "dev"
  account_id  = data.aws_caller_identity.current.account_id

  # dev is created and destroyed freely and holds only throwaway test files, so
  # a destroy should not be blocked by leftover objects.
  force_destroy = true
}
