# The data tier.
#
# One MySQL instance holding run history and promotion tokens for both qa and
# prod, in a VPC of its own, peered to each environment.
#
# WHY THIS IS NOT IN THE qa STACK. qa is destroyed at the end of every session.
# If the shared instance lived there, that destroy would take prod's run
# history and every outstanding promotion token with it - the same failure that
# put the container registry in the shared stack.
#
# WHY THIS IS NOT IN THE shared STACK EITHER. That stack holds the registry and
# the analytics bucket: a few cents a month, and deliberately never torn down.
# An RDS instance is $0.017/hr, which is $12 a month if it is treated the same
# way. Separating them means each stack has one lifecycle - permanent and free,
# or session-scoped and billable - rather than one stack with both.
#
# Apply this before qa: the qa stack reads this stack's outputs to build the
# peering connection.

module "vpc" {
  source = "../../modules/vpc"

  project     = var.project
  environment = "data"
  cidr_block  = var.vpc_cidr

  # Public subnets, so the instance can carry a public endpoint. The promotion
  # gate is checked by a Jenkins job on a laptop; a private-only instance would
  # need a bastion host this project deliberately does not have.
  create_public_subnets = true
}

module "rds" {
  source = "../../modules/rds"

  project    = var.project
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnet_ids

  admin_cidr   = var.admin_cidr
  peered_cidrs = [var.qa_vpc_cidr, var.prod_vpc_cidr]
}

# The MySQL credential is stored once, here, rather than copied into each
# environment's secret set. Both environments' IAM policies allow reading the
# shared prefix, so there is one copy of the password and one place to rotate
# it.
module "secrets" {
  source = "../../modules/secrets-manager"

  project     = var.project
  environment = "shared"

  secrets = {
    rds = jsonencode({
      host     = module.rds.address
      port     = module.rds.port
      database = module.rds.database_name
      username = module.rds.master_username
      password = module.rds.master_password
    })
  }
}
