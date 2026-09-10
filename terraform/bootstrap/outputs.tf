output "state_bucket_name" {
  description = "Name of the Terraform state bucket. Every other stack references this in its backend block."
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_region" {
  description = "Region the state bucket lives in."
  value       = var.aws_region
}

output "backend_config" {
  description = "The backend block the other stacks use, with this stack's actual values filled in."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.tfstate.id}"
        key          = "<dev|qa|prod|shared>/terraform.tfstate"
        region       = "${var.aws_region}"
        encrypt      = true
        use_lockfile = true
      }
    }
  EOT
}
