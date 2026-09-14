variable "project" {
  description = "Project slug."
  type        = string
}

variable "environment" {
  description = "Environment this role serves. The policy is scoped to this environment's buckets and secrets and no others."
  type        = string
}

variable "bucket_arns" {
  description = "ARNs of this environment's five buckets, from the S3 module. Listed explicitly rather than matched by wildcard, so qa's role cannot reach prod's buckets even by accident."
  type        = list(string)
}

variable "secret_name_prefixes" {
  description = "Secrets Manager name prefixes this role may read, e.g. [\"mongo-dcu-pipeline/qa/*\", \"mongo-dcu-pipeline/shared/*\"]. Two rather than one: the environment owns its DocumentDB credential, while the MySQL credential belongs to the shared data tier and is stored once rather than copied into every environment."
  type        = list(string)
}

variable "create_role" {
  description = "Whether to create the IRSA role. An explicit boolean because Terraform must know how many roles to create at plan time, and on the apply that creates the cluster the provider ARN is not known yet."
  type        = bool
  default     = false
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider, which the role's trust policy names. Required when create_role is true."
  type        = string
  default     = ""
}

variable "oidc_provider_url" {
  description = "The cluster's OIDC issuer URL without its https:// prefix. Required when create_role is true."
  type        = string
  default     = ""
}

variable "service_account_namespace" {
  description = "Kubernetes namespace of the service account allowed to assume the role."
  type        = string
  default     = "mongo-dcu"
}

variable "service_account_name" {
  description = "Kubernetes service account allowed to assume the role."
  type        = string
  default     = "mongo-dcu-app"
}
