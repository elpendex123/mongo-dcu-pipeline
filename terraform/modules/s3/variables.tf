variable "project" {
  description = "Project slug, used as the leading component of every bucket name."
  type        = string
}

variable "environment" {
  description = "Environment this bucket set belongs to: dev, qa or prod."
  type        = string

  validation {
    condition     = contains(["dev", "qa", "prod"], var.environment)
    error_message = "environment must be one of: dev, qa, prod."
  }
}

variable "account_id" {
  description = "AWS account ID, appended to every bucket name. S3 bucket names are globally unique across all AWS accounts, so without this suffix an apply could fail on a name another account already owns."
  type        = string
}

variable "bucket_suffixes" {
  description = "The trailing name component of each bucket to create. The full name is {project}-{environment}-{suffix}-{account_id}."
  type        = list(string)
  default     = ["input", "successful", "failed", "reports-json", "reports-log"]
}

variable "force_destroy" {
  description = "Whether `terraform destroy` may delete a bucket that still holds objects. True for environments that are torn down routinely and hold nothing of value; false where an accidental destroy should fail loudly instead."
  type        = bool
  default     = false
}

variable "noncurrent_version_expiration_days" {
  description = "How long superseded object versions are retained before expiry. Versioning protects against an accidental overwrite or delete during a run; old versions should not accumulate indefinitely."
  type        = number
  default     = 30
}
