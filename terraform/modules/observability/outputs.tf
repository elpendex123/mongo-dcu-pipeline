output "grafana_role_arn" {
  description = "Grafana's IAM role. Annotated onto its service account by the generated monitoring values."
  value       = aws_iam_role.this["grafana"].arn
}

output "cloudwatch_agent_role_arn" {
  description = "The CloudWatch agent's IAM role, attached to the add-on."
  value       = aws_iam_role.this["cloudwatch-agent"].arn
}

output "cloudwatch_addon_version" {
  description = "The amazon-cloudwatch-observability version installed."
  value       = aws_eks_addon.cloudwatch.addon_version
}
