# Secrets Manager is the source of truth for credentials; Kubernetes Secrets
# are what the pod actually mounts, and an Ansible playbook bridges the two
# (§15). That split is deliberate: the credential exists once, in a service
# built to hold it, and the cluster gets a copy scoped to one namespace.
#
# Names follow {project}/{environment}/{name}, so one IAM policy can grant
# access to exactly one environment's secrets with a single wildcard.

locals {
  prefix = "${var.project}/${var.environment}"
}

# for_each over the keys rather than the map itself. Marking the map sensitive
# marks its keys sensitive too, and a key becomes part of a resource address -
# which Terraform refuses, reasonably. The names ("docdb", "ses") are not the
# secret; what they point at is, and that stays sensitive.
resource "aws_secretsmanager_secret" "this" {
  for_each = toset(nonsensitive(keys(var.secrets)))

  name                    = "${local.prefix}/${each.key}"
  description             = "${var.project} ${var.environment} - ${each.key}"
  recovery_window_in_days = var.recovery_window_days

  tags = { Name = "${local.prefix}/${each.key}" }
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each = toset(nonsensitive(keys(var.secrets)))

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = var.secrets[each.key]
}
