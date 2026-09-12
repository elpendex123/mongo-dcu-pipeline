# A VPC in one of two shapes.
#
# Private (the default, used by qa and prod): subnets with no route to an
# internet gateway, because there is none. Everything the application needs -
# S3, ECR, Secrets Manager, CloudWatch, STS - arrives through VPC endpoints.
# A NAT gateway would cost $0.045/hr just to exist, cannot be stopped without
# deleting it, and would buy egress this workload never uses.
#
# Public (the data tier): subnets with a route to an internet gateway, so the
# RDS instance can carry a public endpoint. The security group, not the route
# table, is what actually restricts who reaches it.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.project}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /20 per subnet out of a /16: 4094 addresses each, far more than needed, but
  # the EKS VPC CNI assigns a VPC address to every pod, so a subnet sized for
  # the node count rather than the pod count is a trap worth avoiding.
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.cidr_block, 4, i)]
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.cidr_block, 4, i + 8)]
}

resource "aws_vpc" "this" {
  cidr_block = var.cidr_block

  # Both are required for VPC interface endpoints to be usable by name, and for
  # a peered VPC to resolve this one's private DNS.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.name}-private-${local.azs[count.index]}"
    tier = "private"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------- public side

resource "aws_internet_gateway" "this" {
  count = var.create_public_subnets ? 1 : 0

  vpc_id = aws_vpc.this.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  count = var.create_public_subnets ? var.az_count : 0

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.name}-public-${local.azs[count.index]}"
    tier = "public"
  }
}

resource "aws_route_table" "public" {
  count = var.create_public_subnets ? 1 : 0

  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-public" }
}

resource "aws_route" "public_internet" {
  count = var.create_public_subnets ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count = var.create_public_subnets ? var.az_count : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}
