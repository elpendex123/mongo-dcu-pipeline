output "vpc_id" {
  description = "The data tier's VPC. The qa and prod stacks peer with this."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "The data tier's address range, for a peered stack's route table."
  value       = module.vpc.cidr_block
}

output "private_route_table_id" {
  description = "Route table the peered stack adds its return route to."
  value       = module.vpc.private_route_table_id
}

output "public_route_table_id" {
  description = "The public route table. The RDS instance sits in the public subnets, so this - not the private table - is where a peered VPC's return route belongs. Getting this wrong produces a peering connection that is active and a connection that times out."
  value       = module.vpc.public_route_table_id
}

output "rds_endpoint" {
  description = "Host and port for MySQL."
  value       = module.rds.endpoint
}

output "rds_address" {
  description = "MySQL hostname without the port."
  value       = module.rds.address
}

output "rds_database" {
  description = "The schema holding runs, run_lines and email_notifications."
  value       = module.rds.database_name
}

output "rds_security_group_id" {
  description = "The instance's security group."
  value       = module.rds.security_group_id
}

output "rds_secret_name" {
  description = "Secrets Manager entry holding the MySQL credential. Read by the Ansible bridge, never printed."
  value       = module.secrets.secret_names["rds"]
}

output "admin_cidr" {
  description = "The address currently allowed to reach MySQL from outside AWS. A home address is usually dynamic - if a promotion job cannot connect, check this first."
  value       = module.rds.admin_cidr
}

output "mysql_command" {
  description = "How to connect from the Jenkins host, with the password read from Secrets Manager rather than typed."
  value       = "mysql -h ${module.rds.address} -P ${module.rds.port} -u ${module.rds.master_username} -p ${module.rds.database_name}"
}
