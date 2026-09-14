output "ecr_repository_name" {
  description = "Repository name, as used by the AWS CLI and by docker tag."
  value       = aws_ecr_repository.app.name
}

output "ecr_repository_url" {
  description = "Full registry URL. scripts/build-push.sh reads this rather than assembling the host name from the account ID and region."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_registry" {
  description = "Registry host on its own, which is what `docker login` authenticates against."
  value       = split("/", aws_ecr_repository.app.repository_url)[0]
}

output "mirror_registry" {
  description = "What kube-prometheus-stack's global.imageRegistry is set to: the registry host plus the mirror prefix, so upstream paths resolve unchanged beneath it."
  value       = "${split("/", aws_ecr_repository.app.repository_url)[0]}/${var.project}-mirror"
}

output "mirrored_repositories" {
  description = "The mirror repositories, by full name."
  value       = sort([for repository in aws_ecr_repository.mirror : repository.name])
}

output "analytics_bucket" {
  description = "Cross-environment bucket for periodic exports of RDS run history."
  value       = aws_s3_bucket.analytics_exports.id
}
