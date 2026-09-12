# qa environment.
#
# A private VPC with no internet route at all, a DocumentDB cluster, the five
# buckets, this environment's secrets, the application's IAM policy, and a
# peering connection to the data tier so the pods can reach MySQL.
#
# EKS arrives in Phase 7. Everything here is what the cluster will need to
# exist before it is worth creating one.
#
# ORDER: apply terraform/environments/shared-data first. This stack reads that
# stack's outputs to build the peering connection, and will fail at plan time
# if it has never been applied.

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "data" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "shared-data/terraform.tfstate"
    region = var.aws_region
  }
}

# ---------------------------------------------------------------- networking

module "vpc" {
  source = "../../modules/vpc"

  project     = var.project
  environment = "qa"
  cidr_block  = var.vpc_cidr

  # No public subnets and no internet gateway. Nothing in this VPC has a route
  # off it except through the endpoints below and the peering connection.
  create_public_subnets = false
}

module "endpoints" {
  source = "../../modules/vpc-endpoints"

  project     = var.project
  environment = "qa"
  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = module.vpc.cidr_block

  subnet_ids      = module.vpc.private_subnet_ids
  route_table_ids = [module.vpc.private_route_table_id]
}

# ------------------------------------------------------------------- peering
#
# The connection is owned by this stack rather than the data tier's, which
# makes the lifecycle read correctly: the peering exists because qa exists, and
# destroying qa removes it. Requester and accepter are in the same account and
# region, so it can be accepted automatically.

resource "aws_vpc_peering_connection" "data" {
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = data.terraform_remote_state.data.outputs.vpc_id
  auto_accept = true

  tags = { Name = "${var.project}-qa-to-data" }
}

# Without DNS resolution across the peering, a pod resolving the RDS hostname
# gets the instance's PUBLIC address - and this VPC has no internet gateway, so
# the connection times out against a peering link that is up and correct. The
# endpoint name has to resolve to the private address on this side.
resource "aws_vpc_peering_connection_options" "data" {
  vpc_peering_connection_id = aws_vpc_peering_connection.data.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_route" "to_data" {
  route_table_id            = module.vpc.private_route_table_id
  destination_cidr_block    = data.terraform_remote_state.data.outputs.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.data.id
}

# The return route lives in the data tier's route table but is created here,
# for the same reason the connection is: it exists only while qa does, and a
# qa destroy should take it away. It goes in the PUBLIC table because that is
# where the RDS instance's subnets are.
resource "aws_route" "from_data" {
  route_table_id            = data.terraform_remote_state.data.outputs.public_route_table_id
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.data.id
}

# ------------------------------------------------------------------- storage

module "buckets" {
  source = "../../modules/s3"

  project     = var.project
  environment = "qa"
  account_id  = data.aws_caller_identity.current.account_id

  # True, unlike the qa entry in the original design. qa is defined as the
  # place where files are run repeatedly and duplication is expected; its
  # buckets hold test files and their reports, and durable run history is in
  # MySQL. A destroy that fails on leftover objects at the end of every session
  # is a teardown that gets skipped.
  force_destroy = true
}

# ---------------------------------------------------------------- DocumentDB

module "documentdb" {
  source = "../../modules/documentdb"

  project     = var.project
  environment = "qa"
  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = module.vpc.cidr_block
  subnet_ids  = module.vpc.private_subnet_ids
}

# ------------------------------------------------------------------- secrets

module "secrets" {
  source = "../../modules/secrets-manager"

  project     = var.project
  environment = "qa"

  secrets = {
    docdb = jsonencode({
      uri      = module.documentdb.connection_uri
      host     = module.documentdb.endpoint
      port     = module.documentdb.port
      username = module.documentdb.master_username
      password = module.documentdb.master_password
    })

    ses = jsonencode({
      sender    = var.ses_sender
      recipient = var.ses_recipient
      region    = var.aws_region
    })
  }
}

# ----------------------------------------------------------------------- IAM

module "iam" {
  source = "../../modules/iam"

  project     = var.project
  environment = "qa"

  bucket_arns = values(module.buckets.bucket_arns)

  # Two prefixes: this environment's own secrets, and the shared data tier's
  # MySQL credential, which is stored once rather than copied per environment.
  secret_name_prefixes = [
    "${var.project}/qa/*",
    "${var.project}/shared/*",
  ]

  # Empty until Phase 7. The role cannot trust an OIDC provider that does not
  # exist, so this phase produces the policy and the next one attaches it.
  oidc_provider_arn = ""
  oidc_provider_url = ""
}
