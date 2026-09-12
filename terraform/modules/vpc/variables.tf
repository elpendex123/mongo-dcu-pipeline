variable "project" {
  description = "Project slug, used as the leading component of every resource name."
  type        = string
}

variable "environment" {
  description = "Environment this VPC belongs to: qa, prod, or shared for the data tier."
  type        = string
}

variable "cidr_block" {
  description = "The VPC's address range. Ranges must not overlap between environments, because overlapping CIDRs cannot be peered - which is how the pods reach the shared RDS instance."
  type        = string
}

variable "az_count" {
  description = "How many availability zones to spread subnets across. Two is the minimum a DocumentDB or RDS subnet group will accept."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2: DB subnet groups require subnets in two availability zones."
  }
}

variable "create_public_subnets" {
  description = "Whether to create public subnets and an internet gateway. True only for the data tier, whose RDS instance needs a public endpoint so the promotion gate can be checked from a Jenkins job running outside AWS. The qa and prod VPCs are private throughout - the pods reach AWS services through VPC endpoints and have no internet route at all."
  type        = bool
  default     = false
}
