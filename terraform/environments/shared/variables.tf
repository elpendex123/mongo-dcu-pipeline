variable "aws_region" {
  description = "AWS region for all project resources."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project slug. Also the value of the 'project' tag the status and teardown scripts query on."
  type        = string
  default     = "mongo-dcu-pipeline"
}

variable "image_retention_count" {
  description = "How many tagged images the registry keeps. Older ones are expired by the lifecycle policy. Storage is billed per GB-month, and an image nobody can name is an image nobody will deploy."
  type        = number
  default     = 10
}

variable "mirrored_repositories" {
  description = "Upstream image repositories copied into ECR, because the clusters cannot reach a public registry. Paths as kube-prometheus-stack names them, without the registry host or tag: the chart's global.imageRegistry replaces only the host, so each path here has to match. scripts/mirror-images.sh reads the list from the chart and fails, naming this variable, when a repository is missing."
  type        = list(string)
  default = [
    "grafana/grafana",
    "kiwigrid/k8s-sidecar",
    "kube-state-metrics/kube-state-metrics",
    "prometheus/alertmanager",
    "prometheus/node-exporter",
    "prometheus/prometheus",
    "prometheus-operator/prometheus-config-reloader",
    "prometheus-operator/prometheus-operator",
  ]
}

variable "mirror_retention_count" {
  description = "How many tags each mirrored repository keeps. A chart upgrade pushes new tags; the old ones are only needed to roll back one version."
  type        = number
  default     = 3
}

variable "untagged_retention_days" {
  description = "How long an untagged image layer set survives. An image becomes untagged when a tag is moved off it, which happens on every push of a moving tag; these are rebuild artefacts, not history."
  type        = number
  default     = 1
}
