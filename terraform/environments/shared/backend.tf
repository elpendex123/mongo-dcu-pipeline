# Its own state key, separate from dev, qa and prod. This is the whole point of
# the shared stack: a `terraform destroy` in an environment cannot reach these
# resources, because they are not in that environment's state.

terraform {
  backend "s3" {
    bucket       = "mongo-dcu-pipeline-tfstate-950639281723"
    key          = "shared/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
