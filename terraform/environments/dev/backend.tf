# State lives in the bucket created by terraform/bootstrap. Each environment
# has its own key, so dev can be applied and destroyed with no possibility of
# disturbing qa or prod state.
#
# use_lockfile is S3 native locking (Terraform >= 1.10) - no DynamoDB table.

terraform {
  backend "s3" {
    bucket       = "mongo-dcu-pipeline-tfstate-950639281723"
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
