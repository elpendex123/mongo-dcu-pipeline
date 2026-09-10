variable "aws_region" {
  description = "AWS region for all project resources."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project slug. Used as the name prefix and as the value of the 'project' tag that the status and teardown scripts query on."
  type        = string
  default     = "mongo-dcu-pipeline"
}

variable "noncurrent_version_expiration_days" {
  description = "How long superseded state file versions are kept. Versioning is the recovery path for a corrupted or mistakenly-applied state, but old versions should not accumulate forever."
  type        = number
  default     = 90
}
