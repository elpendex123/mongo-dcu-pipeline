output "secret_arns" {
  description = "Map of short name to secret ARN. Secrets Manager appends six random characters to every ARN, so a recreated secret never collides with the one it replaced - which is why nothing hardcodes these."
  value       = { for k, v in aws_secretsmanager_secret.this : k => v.arn }
}

output "secret_names" {
  description = "Map of short name to full secret name. The Ansible bridge reads these."
  value       = { for k, v in aws_secretsmanager_secret.this : k => v.name }
}

output "arn_prefix" {
  description = "Wildcard covering exactly this environment's secrets, for the application's IAM policy."
  value       = "${var.project}/${var.environment}/*"
}
