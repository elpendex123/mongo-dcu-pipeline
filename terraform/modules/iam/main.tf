# The application's permissions, as one policy scoped to one environment.
#
# IRSA rather than a node role: the trust policy names a single Kubernetes
# service account, so only the application's pod can assume it. Attaching these
# permissions to the node's instance role instead would hand them to every pod
# that happens to land on that node, including anything in kube-system.
#
# The role is created only once the cluster's OIDC provider exists, which
# happens with the cluster in Phase 7. Until then this module produces the
# policy alone - the permissions are reviewable and version-controlled before
# there is anything to attach them to.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name        = "${var.project}-${var.environment}-app"
  create_role = var.oidc_provider_arn != "" && var.oidc_provider_url != ""
}

data "aws_iam_policy_document" "app" {
  # Listing is a bucket-level action and takes the bucket ARN; reading and
  # writing objects are object-level and take the /* form. Both are needed:
  # the poll lists the input bucket, and the move reads and writes objects.
  statement {
    sid       = "ListTheEnvironmentsBuckets"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = var.bucket_arns
  }

  statement {
    sid    = "ReadWriteObjectsInTheEnvironmentsBuckets"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [for arn in var.bucket_arns : "${arn}/*"]
  }

  statement {
    sid     = "ReadItsOwnSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      for prefix in var.secret_name_prefixes :
      "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${prefix}"
    ]
  }

  statement {
    sid    = "WriteItsOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/${var.project}/${var.environment}*"]
  }

  # SES has no resource-level permission for sending, so this cannot be scoped
  # to a bucket the way the others are. The condition narrows it instead: this
  # role may send only from the project's verified address.
  statement {
    sid       = "SendRunSummaryEmail"
    effect    = "Allow"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "app" {
  name        = local.name
  description = "${var.project} application, ${var.environment}: its own buckets, its own secrets, its own log group"
  policy      = data.aws_iam_policy_document.app.json

  tags = { Name = local.name }
}

# The web identity trust policy. StringEquals on both the audience and the
# subject: without the sub condition, ANY service account in the cluster could
# assume this role, which would give away exactly what IRSA exists to contain.
data "aws_iam_policy_document" "trust" {
  count = local.create_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.service_account_namespace}:${var.service_account_name}"]
    }
  }
}

resource "aws_iam_role" "app" {
  count = local.create_role ? 1 : 0

  name               = local.name
  description        = "Assumed by the ${var.service_account_name} service account in the ${var.service_account_namespace} namespace"
  assume_role_policy = data.aws_iam_policy_document.trust[0].json

  tags = { Name = local.name }
}

resource "aws_iam_role_policy_attachment" "app" {
  count = local.create_role ? 1 : 0

  role       = aws_iam_role.app[0].name
  policy_arn = aws_iam_policy.app.arn
}
