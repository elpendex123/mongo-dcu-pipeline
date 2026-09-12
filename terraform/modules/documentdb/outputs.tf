output "cluster_identifier" {
  description = "The cluster's identifier."
  value       = aws_docdb_cluster.this.cluster_identifier
}

output "endpoint" {
  description = "The cluster endpoint. AWS assigns the middle portion at creation, so this is read from the output and never typed."
  value       = aws_docdb_cluster.this.endpoint
}

output "port" {
  description = "The port the cluster listens on."
  value       = aws_docdb_cluster.this.port
}

output "master_username" {
  description = "The master user name."
  value       = var.master_username
}

output "master_password" {
  description = "The generated master password. Written into Secrets Manager by the calling stack; never printed."
  value       = random_password.master.result
  sensitive   = true
}

output "connection_uri" {
  description = "A ready-to-use connection URI, TLS enabled. Stored in Secrets Manager and read by the application from there."
  value       = "mongodb://${var.master_username}:${urlencode(random_password.master.result)}@${aws_docdb_cluster.this.endpoint}:${aws_docdb_cluster.this.port}/?tls=true&tlsCAFile=/etc/ssl/certs/global-bundle.pem&replicaSet=rs0&retryWrites=false"
  sensitive   = true
}

output "security_group_id" {
  description = "The cluster's security group."
  value       = aws_security_group.this.id
}
