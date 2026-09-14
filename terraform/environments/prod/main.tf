# prod environment.
#
# The same shape as qa, deliberately: a private VPC with no internet route, a
# DocumentDB cluster, the five buckets, this environment's secrets, an EKS
# cluster, the application's IRSA role, and a peering connection to the data
# tier. What passed in qa should meet the same infrastructure here.
#
# What differs is what reaches it. Nothing arrives in prod's input bucket except
# through scripts/promote.sh, and the application refuses a file that was not
# promoted or has run before (app/promotion.py).
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
  environment = "prod"
  cidr_block  = var.vpc_cidr

  # No public subnets and no internet gateway. Nothing in this VPC has a route
  # off it except through the endpoints below and the peering connection.
  create_public_subnets = false
}

module "endpoints" {
  source = "../../modules/vpc-endpoints"

  project     = var.project
  environment = "prod"
  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = module.vpc.cidr_block

  subnet_ids      = module.vpc.private_subnet_ids
  route_table_ids = [module.vpc.private_route_table_id]
}

# ------------------------------------------------------------------- peering
#
# Owned by this stack, as qa's is by qa: the peering exists because prod
# exists, and destroying prod removes it. The data tier then holds two peering
# connections, one per environment, and two return routes with different
# destinations.

resource "aws_vpc_peering_connection" "data" {
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = data.terraform_remote_state.data.outputs.vpc_id
  auto_accept = true

  tags = { Name = "${var.project}-prod-to-data" }
}

# Without DNS resolution across the peering, a pod resolving the RDS hostname
# gets the instance's PUBLIC address - and this VPC has no internet gateway, so
# the connection times out against a peering link that is up and correct.
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

# In the data tier's PUBLIC table, because that is where the RDS instance's
# subnets are.
resource "aws_route" "from_data" {
  route_table_id            = data.terraform_remote_state.data.outputs.public_route_table_id
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.data.id
}

# ------------------------------------------------------------------- storage

module "buckets" {
  source = "../../modules/s3"

  project     = var.project
  environment = "prod"
  account_id  = data.aws_caller_identity.current.account_id

  # True, and a decision rather than a default. A production system would keep
  # these false, with retention rules: the files and reports are the record of
  # what ran against production. This prod is torn down at the end of every
  # session, and so is the data tier holding its run history - and a destroy
  # that failed on a non-empty bucket would be followed by nuke.sh deleting
  # the bucket anyway. false here would protect nothing and only make every
  # teardown fail first.
  force_destroy = true
}

# ---------------------------------------------------------------- DocumentDB

module "documentdb" {
  source = "../../modules/documentdb"

  project     = var.project
  environment = "prod"
  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = module.vpc.cidr_block
  subnet_ids  = module.vpc.private_subnet_ids
}

# ----------------------------------------------------------------------- EKS

module "eks" {
  source = "../../modules/eks"

  project            = var.project
  environment        = "prod"
  subnet_ids         = module.vpc.private_subnet_ids
  kubernetes_version = var.kubernetes_version

  # Explicit, because nothing in the module's inputs references the endpoints.
  # A node that boots before ecr.dkr and sts exist fails to join the cluster.
  depends_on = [module.endpoints]
}

# ------------------------------------------------------------------- secrets

module "secrets" {
  source = "../../modules/secrets-manager"

  project     = var.project
  environment = "prod"

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
  environment = "prod"

  bucket_arns = values(module.buckets.bucket_arns)
  ses_sender  = var.ses_sender

  # prod's own secrets and the shared MySQL credential. Not qa's: the prod role
  # reaches nothing that belongs to qa.
  secret_name_prefixes = [
    "${var.project}/prod/*",
    "${var.project}/shared/*",
  ]

  create_role       = true
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  # The one service account allowed to assume the role. Created by
  # ansible/playbooks/service-account.yml, not by the Helm chart.
  service_account_namespace = var.app_namespace
  service_account_name      = var.app_service_account
}
