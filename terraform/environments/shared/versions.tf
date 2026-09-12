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

  # environment = "shared" rather than dev, qa or prod. The status and teardown
  # scripts filter on this tag, and everything here is deliberately outside the
  # per-environment lifecycle: destroying qa must not take the registry with it.
  default_tags {
    tags = {
      project     = var.project
      environment = "shared"
      managed_by  = "terraform"
    }
  }
}
