variable "project" {
  description = "Project slug."
  type        = string
}

variable "vpc_id" {
  description = "VPC the instance lives in - the data tier's VPC, not qa's or prod's."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the instance's subnet group. Public subnets, because the instance carries a public endpoint so the promotion gate can be verified from a Jenkins job outside AWS."
  type        = list(string)
}

variable "admin_cidr" {
  description = "The single address allowed to reach MySQL from outside AWS - the machine running Jenkins. A /32. Leave empty to detect the current public address at apply time."
  type        = string
  default     = ""
}

variable "peered_cidrs" {
  description = "Address ranges of the VPCs peered to this one. The qa and prod pods reach MySQL over peering, by private address. Listing a range whose VPC does not exist yet grants nothing, so prod's range is here from the start."
  type        = list(string)
  default     = []
}

variable "instance_class" {
  description = "Instance size. db.t3.micro, roughly $0.017/hr - this holds pipeline metadata, not a workload."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Storage in GB. 20 is the minimum for gp3 on MySQL."
  type        = number
  default     = 20
}

variable "engine_version" {
  description = "MySQL version, matching the local container that stands in for this instance in dev."
  type        = string
  default     = "8.0"
}

variable "database_name" {
  description = "The schema the application writes run history to."
  type        = string
  default     = "mongo_dcu"
}

variable "master_username" {
  description = "Master user. 'admin' is reserved by RDS for MySQL."
  type        = string
  default     = "dcuadmin"
}
