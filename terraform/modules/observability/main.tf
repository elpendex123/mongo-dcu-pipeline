# Observability for one cluster: the CloudWatch half of it, and the AWS
# identity the Prometheus half needs to read CloudWatch.
#
#   amazon-cloudwatch-observability  the EKS add-on - Container Insights, node and
#                                    pod metrics shipped to CloudWatch by an agent
#   cloudwatch-agent role            what that agent writes with
#   grafana role                     what Grafana's CloudWatch data source reads
#                                    with: DocumentDB, RDS and Container Insights
#
# kube-prometheus-stack itself is not here. It is a Helm release
# (ansible/playbooks/deploy-monitoring.yml): configuration inside the cluster,
# changed far more often than the infrastructure under it.

locals {
  name = "${var.project}-${var.environment}"

  # Each role trusts exactly one service account, by namespace and name - the
  # same rule as the application's role. Without the sub condition any service
  # account in the cluster could assume it.
  service_accounts = {
    cloudwatch-agent = "system:serviceaccount:amazon-cloudwatch:cloudwatch-agent"
    grafana          = "system:serviceaccount:${var.monitoring_namespace}:${var.grafana_service_account}"
  }
}

data "aws_iam_policy_document" "trust" {
  for_each = local.service_accounts

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
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.service_accounts

  name               = "${local.name}-${each.key}"
  description        = "Assumed by ${each.value}"
  assume_role_policy = data.aws_iam_policy_document.trust[each.key].json

  tags = { Name = "${local.name}-${each.key}" }
}

# The AWS-managed policy the add-on documents for its agent: write metrics and
# log events, describe the instances and volumes it reports on.
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.this["cloudwatch-agent"].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Read only, and only what the CloudWatch data source calls. Resources are "*"
# because CloudWatch metrics have no resource-level permissions for reads.
data "aws_iam_policy_document" "grafana" {
  statement {
    sid    = "ReadMetricsAndAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetInsightRuleReport",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "QueryLogs"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:GetLogGroupFields",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:GetLogEvents",
    ]
    resources = ["*"]
  }

  # Dimension and region lookups in the query editor.
  statement {
    sid       = "DescribeForTheQueryEditor"
    effect    = "Allow"
    actions   = ["ec2:DescribeTags", "ec2:DescribeInstances", "ec2:DescribeRegions", "tag:GetResources"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "grafana" {
  name   = "${local.name}-grafana-cloudwatch-read"
  role   = aws_iam_role.this["grafana"].id
  policy = data.aws_iam_policy_document.grafana.json
}

# Container Insights, and nothing else the add-on offers.
#
#   containerLogs       off - Splunk takes the logs (Phase 11), and Fluent Bit
#                       would add a pod per node for a copy nobody reads
#   applicationSignals  off - it instruments application code; this one exposes
#                       its own Prometheus metrics
#   kubeStateMetrics,   off - kube-prometheus-stack runs both already, and two
#   nodeExporter        node-exporters want the same host port on every node
#   dcgm, neuron        off - GPU and Inferentia exporters, on nodes that have neither
resource "aws_eks_addon" "cloudwatch" {
  cluster_name             = var.cluster_name
  addon_name               = "amazon-cloudwatch-observability"
  addon_version            = var.cloudwatch_addon_version
  service_account_role_arn = aws_iam_role.this["cloudwatch-agent"].arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    containerInsights  = { enabled = true }
    containerLogs      = { enabled = false }
    applicationSignals = { enabled = false }
    kubeStateMetrics   = { enabled = false }
    nodeExporter       = { enabled = false }
    dcgmExporter       = { enabled = false }
    neuronMonitor      = { enabled = false }
  })

  tags = { Name = "${local.name}-cloudwatch-observability" }

  depends_on = [aws_iam_role_policy_attachment.cloudwatch_agent]
}
