output "bucket_names" {
  description = "Bucket role to bucket name. Feeds the application's local environment file."
  value       = module.buckets.bucket_names
}

output "bucket_name_list" {
  description = "Flat list of the dev buckets."
  value       = module.buckets.bucket_name_list
}

output "env_file_lines" {
  description = "Ready to paste into the Docker Compose environment file for local runs."
  value       = <<-EOT
    S3_INPUT_BUCKET=${module.buckets.bucket_names["input"]}
    S3_SUCCESSFUL_BUCKET=${module.buckets.bucket_names["successful"]}
    S3_FAILED_BUCKET=${module.buckets.bucket_names["failed"]}
    S3_REPORTS_JSON_BUCKET=${module.buckets.bucket_names["reports-json"]}
    S3_REPORTS_LOG_BUCKET=${module.buckets.bucket_names["reports-log"]}
  EOT
}
