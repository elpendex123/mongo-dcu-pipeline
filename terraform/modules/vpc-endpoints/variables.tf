variable "project" {
  description = "Project slug, used as the leading component of every resource name."
  type        = string
}

variable "environment" {
  description = "Environment these endpoints belong to."
  type        = string
}

variable "vpc_id" {
  description = "VPC the endpoints are created in."
  type        = string
}

variable "vpc_cidr" {
  description = "The VPC's address range. The endpoints' security group allows HTTPS from this range and nothing else."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets to place interface endpoints in. Interface endpoints are billed per availability zone, so passing one subnet halves the cost of every endpoint against a two-AZ placement. See interface_endpoint_azs."
  type        = list(string)
}

variable "route_table_ids" {
  description = "Route tables the S3 gateway endpoint is attached to. A gateway endpoint is a route, not an interface: it costs nothing and has no security group."
  type        = list(string)
}

variable "interface_endpoint_azs" {
  description = "How many of the supplied subnets to place each interface endpoint in. One, deliberately: at $0.01 per endpoint per AZ per hour, six endpoints across two AZs is $0.12/hr - more than the DocumentDB instance they exist to support. A node in the other AZ still reaches them, at $0.01/GB of cross-AZ traffic on a workload that moves kilobytes. A production system with real traffic would pay for one per AZ."
  type        = number
  default     = 1
}

variable "interface_services" {
  description = "Service names, without the com.amazonaws.<region>. prefix. Defaults cover what the application and the cluster need with no internet route: ECR for image pulls (two endpoints - the API and the Docker registry are separate services), Secrets Manager for credentials, CloudWatch Logs for the log stream, STS because IRSA obtains credentials by calling AssumeRoleWithWebIdentity, and EC2 because the VPC CNI calls the EC2 API to attach addresses to pods."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "secretsmanager", "logs", "sts", "ec2"]
}
