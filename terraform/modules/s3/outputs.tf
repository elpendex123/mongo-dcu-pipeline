output "bucket_names" {
  description = "Map of bucket role (input, successful, failed, reports-json, reports-log) to full bucket name. The application reads these as environment variables, so it never has to build a bucket name itself."
  value       = { for suffix, bucket in aws_s3_bucket.this : suffix => bucket.id }
}

output "bucket_arns" {
  description = "Map of bucket role to ARN. Consumed by the IAM module to scope the application's policy to exactly this environment's buckets."
  value       = { for suffix, bucket in aws_s3_bucket.this : suffix => bucket.arn }
}

output "bucket_name_list" {
  description = "Flat list of bucket names, for scripts that iterate rather than look up by role."
  value       = sort([for bucket in aws_s3_bucket.this : bucket.id])
}
