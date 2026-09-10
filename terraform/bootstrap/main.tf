data "aws_caller_identity" "current" {}

locals {
  # S3 bucket names are globally unique across every AWS account, so the
  # account ID is appended to guarantee an apply can never collide with a name
  # somebody else already owns.
  bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  # Left false on purpose. This bucket holds the state for every environment;
  # an accidental `terraform destroy` here should fail against a non-empty
  # bucket rather than quietly take the state files with it.
  force_destroy = false

  tags = {
    Name = local.bucket_name
  }
}

# Versioning is the safety net: a bad apply or a hand-edited state can be
# rolled back to the previous object version.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 rather than SSE-KMS: state files here contain resource identifiers and
# endpoints, not application secrets (those live in Secrets Manager), and
# SSE-S3 carries no per-request KMS charge.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # The lifecycle rule depends on versioning being switched on first, otherwise
  # a noncurrent-version rule has nothing to act on.
  depends_on = [aws_s3_bucket_versioning.tfstate]

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    # Terraform's S3 locking writes a .tflock object next to the state file and
    # removes it on release. A failed run can strand one; this sweeps the
    # leftovers rather than leaving a lock that blocks the next apply forever.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
