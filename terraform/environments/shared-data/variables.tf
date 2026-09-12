variable "aws_region" {
  description = "AWS region for all project resources."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project slug. Also the value of the 'project' tag the status and teardown scripts query on."
  type        = string
  default     = "mongo-dcu-pipeline"
}

variable "vpc_cidr" {
  description = "The data tier's address range. Must not overlap qa's 10.10.0.0/16 or prod's 10.20.0.0/16 - overlapping ranges cannot be peered, and peering is how the pods reach this instance."
  type        = string
  default     = "10.0.0.0/16"
}

variable "qa_vpc_cidr" {
  description = "qa's address range, allowed through to MySQL. Listed here before the qa VPC exists; a rule naming a range that has no VPC behind it grants nothing."
  type        = string
  default     = "10.10.0.0/16"
}

variable "prod_vpc_cidr" {
  description = "prod's address range, on the same terms. Present from the start so that bringing prod up in Phase 9 does not require reapplying this stack."
  type        = string
  default     = "10.20.0.0/16"
}

variable "admin_cidr" {
  description = "The address allowed to reach MySQL from outside AWS - where Jenkins runs. Leave empty to detect the current public address at apply time; set it explicitly for a fixed office address."
  type        = string
  default     = ""
}
