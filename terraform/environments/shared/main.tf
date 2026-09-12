# shared stack.
#
# Everything here outlives an individual environment. qa and prod are created
# and destroyed repeatedly - that is the working pattern for this project - and
# both of them pull the same image from the same registry. If the registry
# lived in the qa stack, tearing qa down would delete the image prod runs, and
# rebuilding it would be a precondition for every provision.
#
# So: the container registry and the cross-environment analytics bucket live in
# their own root module, with their own state key, tagged environment=shared.

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# ECR - the application image
# ---------------------------------------------------------------------------

# Tags are mutable on purpose. The build script pushes two tags for every
# build: an immutable one derived from the git commit, which is what the Helm
# release actually references, and a moving `latest` for convenience. Immutable
# tags would reject the second push of `latest` outright. The safety this gives
# up is recovered by never deploying the moving tag.
resource "aws_ecr_repository" "app" {
  name                 = "${var.project}-app"
  image_tag_mutability = "MUTABLE"

  # Scans on push against the AWS-managed CVE database. Basic scanning is free;
  # enhanced scanning is an Inspector charge and would be the first always-on
  # cost in an account that is otherwise billed only while a cluster is up.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # A repository holding images cannot be deleted without this. The images are
  # a build artefact - reproducible from any commit in a minute - so refusing
  # the destroy would protect nothing and only ever strand the stack.
  force_delete = true

  tags = {
    Name = "${var.project}-app"
  }
}

# Rules are evaluated in priority order and a tagStatus = "any" rule must come
# last, since it matches everything after it.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_retention_days} day(s)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_retention_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the ${var.image_retention_count} most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.image_retention_count
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Analytics exports bucket
# ---------------------------------------------------------------------------

# Written out rather than built from modules/s3. That module produces a set of
# five buckets named {project}-{environment}-{role}-{account} for one
# environment; this is a single bucket, belongs to no environment, and its name
# does not carry an environment component at all. Forcing it through the module
# would mean adding a name override and relaxing the environment validation to
# accommodate one bucket - more indirection than writing the four protection
# resources here.
resource "aws_s3_bucket" "analytics_exports" {
  bucket = "${var.project}-analytics-exports-${data.aws_caller_identity.current.account_id}"

  # Contents are periodic exports of RDS run history, regenerable from the
  # database itself, so a destroy should not be blocked by them.
  force_destroy = true

  tags = {
    Name = "${var.project}-analytics-exports-${data.aws_caller_identity.current.account_id}"
    role = "analytics-exports"
  }
}

resource "aws_s3_bucket_versioning" "analytics_exports" {
  bucket = aws_s3_bucket.analytics_exports.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "analytics_exports" {
  bucket = aws_s3_bucket.analytics_exports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "analytics_exports" {
  bucket = aws_s3_bucket.analytics_exports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "analytics_exports" {
  bucket     = aws_s3_bucket.analytics_exports.id
  depends_on = [aws_s3_bucket_versioning.analytics_exports]

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
