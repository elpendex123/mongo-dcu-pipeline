variable "project" {
  description = "Project slug, the leading component of every resource name."
  type        = string
}

variable "environment" {
  description = "Environment this cluster serves: qa or prod. One cluster per environment, never shared namespaces on one."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the control plane's network interfaces and for the nodes. Two availability zones minimum - EKS refuses one."
  type        = list(string)
}

variable "kubernetes_version" {
  description = "Kubernetes minor version. Pinned rather than left to the EKS default, so a new default arriving between sessions cannot change the cluster under a working chart. List what is available with: aws eks describe-cluster-versions."
  type        = string
  default     = "1.36"
}

variable "node_instance_type" {
  description = "Node size. t3.small is the smallest that clears the max-pods ceiling: the VPC CNI gives a t3.small 11 pod addresses, and the system add-ons take three of them on every node before anything else is scheduled."
  type        = string
  default     = "t3.small"
}

variable "node_count" {
  description = "Fixed node count. Two, for infrastructure resilience rather than capacity: if the node running the app pod fails, the pod is rescheduled onto the other within about a minute instead of waiting for a new instance."
  type        = number
  default     = 2
}

variable "node_disk_size" {
  description = "Root volume size in GB. 20 holds the node image plus the application image and the system add-on images with room to spare."
  type        = number
  default     = 20
}

variable "admin_cidr" {
  description = "The single address allowed to reach the public side of the Kubernetes API - the machine running kubectl, Helm, Ansible and Jenkins. Leave empty to detect the current public address at apply time, the same rule the RDS instance uses."
  type        = string
  default     = ""
}

variable "control_plane_log_types" {
  description = "Control plane log types to send to CloudWatch (api, audit, authenticator, controllerManager, scheduler). Empty by default: every type is billed per GB ingested, and EKS creates the log group itself, outside Terraform, so it survives a destroy."
  type        = list(string)
  default     = []
}
