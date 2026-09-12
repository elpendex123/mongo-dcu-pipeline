# One shared MySQL instance, holding run history and promotion tokens for both
# qa and prod. Every table carries an environment column, which is what makes a
# single query across both environments possible - the reason it is shared
# rather than duplicated per environment.
#
# It lives in the data tier's own VPC rather than in qa's, so that destroying
# qa - which happens at the end of every session - cannot take prod's run
# history and its promotion tokens with it. The same reasoning that put the
# container registry in the shared stack.
#
# It carries a public endpoint. The promotion gate is checked by a Jenkins job
# running on a laptop, outside AWS, and a private-only instance would need a
# bastion host - a long-lived server this project deliberately does not have.
# The security group, not the absence of a public address, is the control:
# three sources, everything else denied.

data "http" "my_ip" {
  count = var.admin_cidr == "" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  name = "${var.project}-rds"

  # A home address is usually dynamic. Detected at apply time when not given
  # explicitly, and status.sh reports when the rule no longer matches where you
  # are connecting from.
  admin_cidr = var.admin_cidr != "" ? var.admin_cidr : "${chomp(data.http.my_ip[0].response_body)}/32"
}

resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "!#%^*()-_=+[]{}<>:?"
}

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = var.subnet_ids

  tags = { Name = local.name }
}

resource "aws_security_group" "this" {
  name        = "${local.name}-sg"
  description = "MySQL from the Jenkins host and from the peered environment VPCs"
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "admin" {
  security_group_id = aws_security_group.this.id
  description       = "MySQL from the machine running Jenkins"
  cidr_ipv4         = local.admin_cidr
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "peered" {
  for_each = toset(var.peered_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "MySQL from peered VPC ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
}

resource "aws_db_instance" "this" {
  identifier = local.name

  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.database_name
  username = var.master_username
  password = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = true

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  # A minor version arriving during a maintenance window would change the
  # engine under a running session for no benefit here.
  auto_minor_version_upgrade = false

  # Without this the instance is unreachable by name from a peered VPC, which
  # is how every pod reaches it.
  multi_az = false

  tags = { Name = local.name }
}
