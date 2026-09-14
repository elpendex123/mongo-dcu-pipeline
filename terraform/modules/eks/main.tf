# EKS, one cluster per environment.
#
# The cluster sits in a VPC with no internet route. Nothing here works without
# the endpoints Phase 6 created for it: nodes pull images through ecr.api and
# ecr.dkr with the layers arriving through the S3 gateway, the VPC CNI attaches
# pod addresses through the ec2 endpoint, and a pod using IRSA exchanges its
# service account token for credentials through the sts endpoint.
#
# The API server is reachable two ways. Nodes use the private endpoint, from
# inside the VPC. kubectl, Helm and Ansible run on the machine that runs
# Jenkins, outside AWS, so a public endpoint exists as well - restricted to that
# one address, the same control the RDS instance applies.

data "http" "my_ip" {
  count = var.admin_cidr == "" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

# Provider default_tags reach every resource Terraform creates, but not the
# instances and volumes EC2 launches from a launch template. Those take their
# tags from tag_specifications, so the defaults are read here and passed on -
# an untagged node is one the status script cannot see.
data "aws_default_tags" "current" {}

locals {
  name       = "${var.project}-${var.environment}"
  admin_cidr = var.admin_cidr != "" ? var.admin_cidr : "${chomp(data.http.my_ip[0].response_body)}/32"
}

# ------------------------------------------------------------- control plane

data "aws_iam_policy_document" "cluster_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name}-eks-cluster"
  description        = "Assumed by the EKS control plane of ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.cluster_trust.json

  tags = { Name = "${local.name}-eks-cluster" }
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = local.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = [local.admin_cidr]
  }

  # Access entries rather than the aws-auth ConfigMap. Who may use the cluster
  # is then an AWS API resource Terraform can see, not a YAML file inside the
  # cluster that a bad edit can lock everyone out of. The identity that creates
  # the cluster is made its administrator.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # A version that leaves standard support moves to extended support
  # automatically, and extended support bills $0.60/hr per cluster instead of
  # $0.10. STANDARD means EKS upgrades the cluster instead - which, for an
  # environment rebuilt every session, is the cheaper surprise by far.
  upgrade_policy {
    support_type = "STANDARD"
  }

  # The VPC CNI, kube-proxy and CoreDNS are installed below as managed add-ons,
  # with versions Terraform records, rather than silently by EKS at creation.
  bootstrap_self_managed_addons = false

  enabled_cluster_log_types = var.control_plane_log_types

  tags = { Name = local.name }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# The identity provider IRSA trusts. Each cluster has its own issuer URL, and an
# IAM role can only trust a service account token signed by a provider that is
# registered here. No thumbprint: IAM verifies EKS issuers against its own
# trusted certificate authorities.
resource "aws_iam_openid_connect_provider" "this" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]

  tags = { Name = "${local.name}-oidc" }
}

# --------------------------------------------------------------------- nodes

data "aws_iam_policy_document" "node_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name}-eks-node"
  description        = "Instance role for the ${local.name} node group"
  assume_role_policy = data.aws_iam_policy_document.node_trust.json

  tags = { Name = "${local.name}-eks-node" }
}

# What a node needs and nothing the application needs. The application's own
# permissions are on its IRSA role - see the launch template below for why a
# pod cannot simply borrow these instead.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_launch_template" "node" {
  name                   = "${local.name}-node"
  description            = "Nodes for ${local.name}: IMDSv2 only, one network hop"
  update_default_version = true

  # IMDSv2 with a hop limit of one. A pod's traffic to the instance metadata
  # service crosses an extra network hop, so with a limit of one the request
  # never arrives - and a pod cannot read the NODE's credentials. Without this,
  # every pod on the node could act as the node role, which is precisely the
  # leak IRSA exists to close. Pods that legitimately need AWS
  # get their own role through their service account.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(data.aws_default_tags.current.tags, { Name = "${local.name}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(data.aws_default_tags.current.tags, { Name = "${local.name}-node" })
  }

  tags = { Name = "${local.name}-node" }
}

# ------------------------------------------------------------------ add-ons
#
# The VPC CNI and kube-proxy go on before the nodes: a node without a network
# plugin registers and then sits NotReady. CoreDNS is a Deployment rather than a
# DaemonSet, so it has nowhere to run until nodes exist and goes on after them.

resource "aws_eks_addon" "before_nodes" {
  for_each = toset(["vpc-cni", "kube-proxy"])

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = { Name = "${local.name}-${each.value}" }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = [var.node_instance_type]

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  # Fixed size, no autoscaling: min, desired and max are the same number. The
  # application is one replica by design and has nothing to
  # scale out to.
  scaling_config {
    min_size     = var.node_count
    desired_size = var.node_count
    max_size     = var.node_count
  }

  update_config {
    max_unavailable = 1
  }

  tags = { Name = "${local.name}-nodes" }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.before_nodes,
  ]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = { Name = "${local.name}-coredns" }

  depends_on = [aws_eks_node_group.this]
}
