output "vpc_id" {
  description = "qa's VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets. The EKS node group goes here in Phase 7."
  value       = module.vpc.private_subnet_ids
}

output "bucket_names" {
  description = "Bucket role to bucket name."
  value       = module.buckets.bucket_names
}

output "documentdb_endpoint" {
  description = "The DocumentDB cluster endpoint. Reachable only from inside this VPC."
  value       = module.documentdb.endpoint
}

output "rds_endpoint" {
  description = "MySQL, in the data tier's VPC, reached over the peering connection."
  value       = data.terraform_remote_state.data.outputs.rds_endpoint
}

output "peering_connection_id" {
  description = "The connection to the data tier."
  value       = aws_vpc_peering_connection.data.id
}

output "secret_names" {
  description = "This environment's secrets. The Ansible bridge reads these and creates the matching Kubernetes Secrets."
  value       = module.secrets.secret_names
}

output "app_policy_arn" {
  description = "The application's IAM policy. Attached to an IRSA role once the cluster exists."
  value       = module.iam.policy_arn
}

output "irsa_status" {
  description = "Whether the IRSA role exists yet."
  value       = module.iam.service_account_annotation
}

output "endpoints_hourly_cost" {
  description = "Approximate USD per hour for this VPC's interface endpoints."
  value       = module.endpoints.hourly_cost_estimate
}

output "app_config" {
  description = "The environment variables the application needs in this environment, ready for the Helm values file. Nothing here is typed by hand."
  value = {
    ENVIRONMENT            = "qa"
    S3_INPUT_BUCKET        = module.buckets.bucket_names["input"]
    S3_SUCCESSFUL_BUCKET   = module.buckets.bucket_names["successful"]
    S3_FAILED_BUCKET       = module.buckets.bucket_names["failed"]
    S3_REPORTS_JSON_BUCKET = module.buckets.bucket_names["reports-json"]
    S3_REPORTS_LOG_BUCKET  = module.buckets.bucket_names["reports-log"]
    POLL_INTERVAL_SECONDS  = var.poll_interval_seconds
    AWS_REGION             = var.aws_region
    DOCDB_SECRET_NAME      = module.secrets.secret_names["docdb"]
    RDS_SECRET_NAME        = data.terraform_remote_state.data.outputs.rds_secret_name
    SES_SECRET_NAME        = module.secrets.secret_names["ses"]
  }
}
