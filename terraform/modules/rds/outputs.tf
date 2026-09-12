output "identifier" {
  description = "The instance identifier."
  value       = aws_db_instance.this.identifier
}

output "endpoint" {
  description = "Host and port. AWS assigns the middle portion of the hostname at creation."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "Hostname on its own, without the port."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "The port MySQL listens on."
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "The schema holding runs, run_lines and email_notifications."
  value       = aws_db_instance.this.db_name
}

output "master_username" {
  description = "The master user name."
  value       = var.master_username
}

output "master_password" {
  description = "The generated master password. Written into Secrets Manager by the calling stack."
  value       = random_password.master.result
  sensitive   = true
}

output "security_group_id" {
  description = "The instance's security group."
  value       = aws_security_group.this.id
}

output "admin_cidr" {
  description = "The address currently allowed to reach MySQL from outside AWS. Detected at apply time unless set explicitly - and a home address that has changed since is the first thing to check when a promotion job cannot connect."
  value       = local.admin_cidr
}
