# No provider block here on purpose. A module inherits the provider the calling
# root module configured, which is what makes this module reusable across dev,
# qa and prod without each one needing its own copy of the provider settings.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
