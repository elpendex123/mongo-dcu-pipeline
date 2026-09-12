# VPC endpoints, in place of a NAT gateway.
#
# The application reaches S3, ECR, Secrets Manager, CloudWatch Logs and STS,
# and nothing else. None of that needs general internet egress, and a NAT
# gateway would cost $0.045/hr merely to exist - it cannot be stopped, only
# deleted - for access this workload never uses.
#
# An S3 gateway endpoint is free and is a route table entry rather than an
# interface. Everything else is an interface endpoint: an elastic network
# interface with a private address in each subnet it is placed in, which is
# also why it is billed per availability zone.

data "aws_region" "current" {}

locals {
  name = "${var.project}-${var.environment}"

  # Placing an endpoint in a subset of the supplied subnets is the single
  # largest cost lever in this VPC.
  endpoint_subnets = slice(var.subnet_ids, 0, min(var.interface_endpoint_azs, length(var.subnet_ids)))
}

# Endpoints are reached over HTTPS from inside the VPC only. There is no path
# to them from anywhere else, and this group says so explicitly rather than
# relying on that being true.
resource "aws_security_group" "endpoints" {
  name        = "${local.name}-vpc-endpoints"
  description = "HTTPS from within the VPC to the interface endpoints"
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name}-vpc-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "https_from_vpc" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from within the VPC"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids

  tags = { Name = "${local.name}-s3" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_services)

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = local.endpoint_subnets
  security_group_ids = [aws_security_group.endpoints.id]

  # Without this, code in the VPC resolves the service's public name to a
  # public address and the call leaves for an internet gateway that is not
  # there. The endpoint would exist and nothing would use it.
  private_dns_enabled = true

  tags = { Name = "${local.name}-${each.value}" }
}
