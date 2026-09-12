variable "project" {
  description = "Project slug."
  type        = string
}

variable "environment" {
  description = "Environment this cluster serves: qa or prod."
  type        = string
}

variable "vpc_id" {
  description = "VPC the cluster lives in."
  type        = string
}

variable "vpc_cidr" {
  description = "The VPC's address range. The cluster's security group accepts connections from here and nowhere else - there is no public endpoint and no path in from outside the VPC."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the cluster's subnet group. Two availability zones minimum."
  type        = list(string)
}

variable "instance_class" {
  description = "Instance size. db.t3.medium is the smallest DocumentDB offers, at roughly $0.077/hr."
  type        = string
  default     = "db.t3.medium"
}

variable "instance_count" {
  description = "How many instances in the cluster. One: a replica would double the largest line in this project's hourly cost to protect data that is reseeded from a file on demand."
  type        = number
  default     = 1
}

variable "engine_version" {
  description = "DocumentDB engine version. Pinned to the 5.0 line the local MongoDB container is aligned with, so behaviour is the same from local to qa to prod."
  type        = string
  default     = "5.0.0"
}

variable "master_username" {
  description = "Master user. Not 'admin' or 'root', both of which DocumentDB reserves."
  type        = string
  default     = "dcuadmin"
}
