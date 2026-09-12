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
  description = "qa's address range. Must not overlap the data tier's 10.0.0.0/16 or prod's 10.20.0.0/16."
  type        = string
  default     = "10.10.0.0/16"
}

variable "state_bucket" {
  description = "Bucket holding every stack's state. Read here to reach the data tier's outputs for the peering connection."
  type        = string
  default     = "mongo-dcu-pipeline-tfstate-950639281723"
}

variable "ses_sender" {
  description = "Verified SES address run summary emails are sent from. SES starts in sandbox mode, where the recipient must be verified too."
  type        = string
  default     = "enrique.ruben.coello@gmail.com"
}

variable "ses_recipient" {
  description = "Where run summary emails go."
  type        = string
  default     = "enrique.ruben.coello@gmail.com"
}

variable "poll_interval_seconds" {
  description = "How often the application polls the input bucket."
  type        = number
  default     = 20
}
