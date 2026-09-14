output "vpc_id" {
  description = "qa's VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets, shared by DocumentDB, the EKS control plane's network interfaces and the nodes."
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

output "rds_secret_name" {
  description = "The data tier's MySQL credential, which the bridge copies into this environment's cluster as well."
  value       = data.terraform_remote_state.data.outputs.rds_secret_name
}

output "app_policy_arn" {
  description = "The application's IAM policy."
  value       = module.iam.policy_arn
}

output "cluster_name" {
  description = "The EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "The Kubernetes API server. AWS assigns the hostname at creation."
  value       = module.eks.cluster_endpoint
}

output "kubernetes_version" {
  description = "Kubernetes minor version the control plane runs."
  value       = module.eks.cluster_version
}

output "eks_public_access_cidr" {
  description = "The one address allowed to the public side of the API server. When kubectl starts timing out, compare it with curl -s https://checkip.amazonaws.com."
  value       = module.eks.public_access_cidr
}

output "oidc_provider_arn" {
  description = "The cluster's IAM OIDC provider, trusted by the IRSA role."
  value       = module.eks.oidc_provider_arn
}

output "irsa_role_arn" {
  description = "The application's IAM role. Annotated onto its Kubernetes service account."
  value       = module.iam.role_arn
}

output "irsa_status" {
  description = "The service account annotation, or why there is none."
  value       = module.iam.service_account_annotation
}

output "kubeconfig_command" {
  description = "Points kubectl at this cluster, with a context named after the cluster rather than its ARN."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region} --alias ${module.eks.cluster_name}"
}

output "endpoints_hourly_cost" {
  description = "Approximate USD per hour for this VPC's interface endpoints."
  value       = module.endpoints.hourly_cost_estimate
}

output "app_config" {
  description = "The application's non-secret environment variables in this environment, keyed exactly as app/config.py reads them. Rendered into Helm values by ansible/playbooks/render-values.yml; credentials arrive separately, from Kubernetes Secrets."
  value = {
    APP_ENV    = "qa"
    AWS_REGION = var.aws_region
    # botocore takes its default region from AWS_DEFAULT_REGION and ignores
    # AWS_REGION. The application passes its region to its own clients, but the
    # credential provider that exchanges the IRSA token builds a separate STS
    # client from the default - and with no default it calls the global
    # sts.amazonaws.com, which this VPC cannot reach. The first AWS call then
    # hangs for minutes with no error (issue 17).
    AWS_DEFAULT_REGION     = var.aws_region
    POLL_INTERVAL_SECONDS  = var.poll_interval_seconds
    S3_INPUT_BUCKET        = module.buckets.bucket_names["input"]
    S3_SUCCESSFUL_BUCKET   = module.buckets.bucket_names["successful"]
    S3_FAILED_BUCKET       = module.buckets.bucket_names["failed"]
    S3_REPORTS_JSON_BUCKET = module.buckets.bucket_names["reports-json"]
    S3_REPORTS_LOG_BUCKET  = module.buckets.bucket_names["reports-log"]
  }
}
