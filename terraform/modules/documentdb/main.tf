# DocumentDB, one cluster per environment.
#
# Private throughout: no public endpoint exists, and the security group accepts
# traffic only from inside the VPC. Everything that talks to it - the
# application pod, the Ansible seeding playbook - runs in the cluster.

locals {
  name = "${var.project}-docdb-${var.environment}"
}

# Generated rather than chosen, and never written to a variable file or the
# shell history. Terraform keeps it in state, Secrets Manager is what anything
# else reads it from.
resource "random_password" "master" {
  length = 32
  # DocumentDB rejects '/', '@', '"' and space in a master password, and a
  # password that reaches a connection URI unescaped breaks it anyway.
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
  description = "DocumentDB access from within the VPC only"
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "from_vpc" {
  security_group_id = aws_security_group.this.id
  description       = "MongoDB wire protocol from within the VPC"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 27017
  to_port           = 27017
  ip_protocol       = "tcp"
}

# TLS stays on, which is the DocumentDB default. The cost is that a client must
# present the Amazon RDS CA bundle, so the application image carries it and the
# connection string sets tls=true - the alternative is disabling transport
# encryption on a database holding the data the pipeline exists to change.
resource "aws_docdb_cluster_parameter_group" "this" {
  name        = local.name
  family      = "docdb5.0"
  description = "${var.project} ${var.environment} - TLS enforced, profiler on for slow queries"

  parameter {
    name  = "tls"
    value = "enabled"
  }

  parameter {
    name  = "profiler"
    value = "enabled"
  }

  parameter {
    name  = "profiler_threshold_ms"
    value = "500"
  }
}

resource "aws_docdb_cluster" "this" {
  cluster_identifier = local.name
  engine             = "docdb"
  engine_version     = var.engine_version

  master_username = var.master_username
  master_password = random_password.master.result

  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.this.id]
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.this.name

  # One day, the minimum. The data is 100 documents reseeded from a file in
  # seconds; retaining a week of backups would protect nothing that a rerun of
  # the seeding playbook does not.
  backup_retention_period = 1
  preferred_backup_window = "03:00-04:00"

  # This environment is created and destroyed every session. A final snapshot
  # on every destroy would accumulate storage nobody ever restores.
  skip_final_snapshot = true

  storage_encrypted = true

  enabled_cloudwatch_logs_exports = ["audit", "profiler"]

  tags = { Name = local.name }
}

resource "aws_docdb_cluster_instance" "this" {
  count = var.instance_count

  identifier         = "${local.name}-${count.index + 1}"
  cluster_identifier = aws_docdb_cluster.this.id
  instance_class     = var.instance_class

  tags = { Name = "${local.name}-${count.index + 1}" }
}
