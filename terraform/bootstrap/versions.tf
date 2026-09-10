# Bootstrap stack — creates the S3 bucket that every other stack in this
# project uses as its Terraform backend.
#
# This stack deliberately has NO backend block. It cannot store its state in
# the bucket it is responsible for creating, so its state stays local. That is
# the entire reason it exists as a separate, deliberately tiny stack: run it
# once, and every other stack gets a proper remote backend from then on.
#
# State locking uses S3 natively (use_lockfile) rather than a DynamoDB table —
# supported since Terraform 1.10, and one fewer service to provision, pay for,
# and remember to delete.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Applied to every taggable resource this provider creates. Resource
  # discovery for the status and teardown scripts is tag-based, so a resource
  # that escapes this tag is a resource that escapes the cleanup sweep.
  default_tags {
    tags = {
      project     = var.project
      environment = "shared"
      managed_by  = "terraform"
    }
  }
}
