output "policy_arn" {
  description = "The application's policy. Exists whether or not the cluster does."
  value       = aws_iam_policy.app.arn
}

output "role_arn" {
  description = "The IRSA role, or an empty string while no cluster OIDC provider has been supplied. This is the value that annotates the Kubernetes service account."
  value       = try(aws_iam_role.app[0].arn, "")
}

output "role_name" {
  description = "The IRSA role name, or an empty string."
  value       = try(aws_iam_role.app[0].name, "")
}

output "service_account_annotation" {
  description = "Ready to paste into the Helm chart's service account annotations once the role exists."
  value       = local.create_role ? "eks.amazonaws.com/role-arn: ${aws_iam_role.app[0].arn}" : "(no role yet - the cluster's OIDC provider arrives in Phase 7)"
}
