variable "project" {
  description = "Project slug, the leading component of every resource name."
  type        = string
}

variable "environment" {
  description = "Environment this cluster serves: qa or prod."
  type        = string
}

variable "cluster_name" {
  description = "The EKS cluster the CloudWatch add-on is installed into."
  type        = string
}

variable "oidc_provider_arn" {
  description = "The cluster's IAM OIDC provider, which both roles here trust."
  type        = string
}

variable "oidc_provider_url" {
  description = "The provider's issuer, without https://, as it appears in a trust policy's condition keys."
  type        = string
}

variable "cloudwatch_addon_version" {
  description = "amazon-cloudwatch-observability add-on version. Pinned, like the Kubernetes version, so a new default cannot change the cluster between sessions. List what is available with: aws eks describe-addon-versions --addon-name amazon-cloudwatch-observability --kubernetes-version 1.36."
  type        = string
  default     = "v6.6.0-eksbuild.1"
}

variable "monitoring_namespace" {
  description = "Namespace kube-prometheus-stack runs in."
  type        = string
  default     = "monitoring"
}

variable "grafana_service_account" {
  description = "Grafana's service account. kube-prometheus-stack names it <release>-grafana, and the release is monitoring_release in ansible/inventory/group_vars/all.yml. Rename one and the other has to follow, or Grafana loses its CloudWatch identity with nothing in its log but an access error."
  type        = string
  default     = "kube-prometheus-stack-grafana"
}
