resource "random_id" "backups_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "backups" {
  bucket = "homelab-backups-${random_id.backups_suffix.hex}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "velero-glacier-ir"
    status = "Enabled"

    filter {
      prefix = "velero/"
    }

    transition {
      days          = 14
      storage_class = "GLACIER_IR"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_iam_user" "velero" {
  name = "homelab-velero"
}

resource "aws_iam_user_policy" "velero" {
  name = "homelab-velero-s3"
  user = aws_iam_user.velero.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.backups.arn}/velero/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.backups.arn
        Condition = {
          StringLike = { "s3:prefix" = ["velero", "velero/*"] }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
        ]
        Resource = aws_s3_bucket.backups.arn
      },
    ]
  })
}

resource "aws_iam_access_key" "velero" {
  user = aws_iam_user.velero.name
}

output "backups_bucket" {
  description = "Name of the S3 bucket holding off-cluster backups (Velero + future consumers)"
  value       = aws_s3_bucket.backups.bucket
}

output "velero_access_key_id" {
  description = "Access key ID for the Velero backup user. Copy into the SOPS secret."
  value       = aws_iam_access_key.velero.id
  sensitive   = true
}

output "velero_secret_access_key" {
  description = "Secret access key for the Velero backup user. Copy into the SOPS secret."
  value       = aws_iam_access_key.velero.secret
  sensitive   = true
}
