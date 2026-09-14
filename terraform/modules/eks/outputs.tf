output "cluster_name" {
  description = "The cluster's name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "The Kubernetes API server URL. AWS assigns the hostname at creation."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes minor version the control plane runs."
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "The security group EKS creates for the control plane and attaches to managed nodes. Created and deleted by EKS, not by Terraform."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "The IAM OIDC provider for this cluster. IRSA role trust policies name it as their federated principal."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "The issuer URL without https:// - the form IAM condition keys use (<issuer>:sub, <issuer>:aud)."
  value       = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

output "node_group_name" {
  description = "The managed node group."
  value       = aws_eks_node_group.this.node_group_name
}

output "node_role_arn" {
  description = "The nodes' instance role. Pods cannot reach it - see the launch template's hop limit."
  value       = aws_iam_role.node.arn
}

output "public_access_cidr" {
  description = "The one address allowed to the public side of the API server. A home address changes; when kubectl starts timing out, compare this with curl -s https://checkip.amazonaws.com."
  value       = local.admin_cidr
}
