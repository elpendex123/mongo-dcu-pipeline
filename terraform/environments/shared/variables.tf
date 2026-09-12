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

variable "image_retention_count" {
  description = "How many tagged images the registry keeps. Older ones are expired by the lifecycle policy. Storage is billed per GB-month, and an image nobody can name is an image nobody will deploy."
  type        = number
  default     = 10
}

variable "untagged_retention_days" {
  description = "How long an untagged image layer set survives. An image becomes untagged when a tag is moved off it, which happens on every push of a moving tag; these are rebuild artefacts, not history."
  type        = number
  default     = 1
}
