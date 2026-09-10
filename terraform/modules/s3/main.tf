locals {
  # suffix => full bucket name, e.g.
  #   "input" => "mongo-dcu-pipeline-dev-input-950639281723"
  # Keying every resource by suffix rather than by list index means adding or
  # removing a bucket later does not shift the others' addresses in state and
  # force needless recreation.
  buckets = {
    for suffix in var.bucket_suffixes :
    suffix => "${var.project}-${var.environment}-${suffix}-${var.account_id}"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = each.value
  force_destroy = var.force_destroy

  tags = {
    Name = each.value
    role = each.key
  }
}

# Versioning covers the pipeline's own moves: a file is relocated between
# buckets with copy-then-delete, and a report is overwritten if a run is
# repeated. Versioning makes both recoverable.
resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 rather than SSE-KMS. These buckets hold query files and run reports,
# not credentials, and SSE-S3 avoids a per-request KMS charge on a workload
# that reads and writes objects on every polling cycle.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  # Without this the rule can be created before versioning is enabled, leaving
  # a noncurrent-version rule with nothing to act on.
  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
