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

# Versioning turns Velero's deletes into delete markers, so a compromised cluster cannot
# destroy backup history with the credentials it holds. Velero keeps s3:DeleteObject, so
# its own TTL expiry still behaves normally.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
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

  # The recovery window for a delete that should not have happened. Long enough to notice,
  # short enough that superseded versions do not accumulate cost forever.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
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
      # Neither is granted above, so this only guards against a future widening of the
      # Allow statements: an explicit Deny cannot be overridden by one.
      {
        Effect = "Deny"
        Action = [
          "s3:DeleteObjectVersion",
          "s3:PutBucketVersioning",
          "s3:PutLifecycleConfiguration",
        ]
        Resource = [
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_access_key" "velero" {
  user = aws_iam_user.velero.name
}

resource "aws_iam_user" "minecraft_backup" {
  name = "homelab-minecraft-backup"
}

resource "aws_iam_user_policy" "minecraft_backup" {
  name = "homelab-minecraft-backup-s3"
  user = aws_iam_user.minecraft_backup.name

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
        Resource = "${aws_s3_bucket.backups.arn}/minecraft/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.backups.arn
        Condition = {
          StringLike = { "s3:prefix" = ["minecraft", "minecraft/*"] }
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
      # Same guard as the Velero user: an explicit Deny survives a future widening of the
      # Allow statements above.
      {
        Effect = "Deny"
        Action = [
          "s3:DeleteObjectVersion",
          "s3:PutBucketVersioning",
          "s3:PutLifecycleConfiguration",
        ]
        Resource = [
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_access_key" "minecraft_backup" {
  user = aws_iam_user.minecraft_backup.name
}

locals {
  # Each app gets its own Postgres cluster, so each gets its own prefix and its own user.
  cnpg_apps = toset(["vaultwarden", "shlink"])
}

resource "aws_iam_user" "cnpg" {
  for_each = local.cnpg_apps
  name     = "homelab-cnpg-${each.key}"
}

resource "aws_iam_user_policy" "cnpg" {
  for_each = local.cnpg_apps
  name     = "homelab-cnpg-${each.key}-s3"
  user     = aws_iam_user.cnpg[each.key].name

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
        Resource = "${aws_s3_bucket.backups.arn}/cnpg/${each.key}/*"
      },
      # Unconditioned on purpose. barman-cloud opens with a HeadBucket call, which is
      # governed by s3:ListBucket but carries no s3:prefix key — a prefix condition can
      # never match it, and every backup fails 403. Listing keys is all this grants; reads
      # and writes stay pinned to cnpg/${each.key}/ by the statement above.
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.backups.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
        ]
        Resource = aws_s3_bucket.backups.arn
      },
      # Same guard as the Velero user: an explicit Deny survives a future widening of the
      # Allow statements above.
      {
        Effect = "Deny"
        Action = [
          "s3:DeleteObjectVersion",
          "s3:PutBucketVersioning",
          "s3:PutLifecycleConfiguration",
        ]
        Resource = [
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_access_key" "cnpg" {
  for_each = local.cnpg_apps
  user     = aws_iam_user.cnpg[each.key].name
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

output "minecraft_backup_access_key_id" {
  description = "Access key ID for the Minecraft restic backup user. Copy into the SOPS secret."
  value       = aws_iam_access_key.minecraft_backup.id
  sensitive   = true
}

output "minecraft_backup_secret_access_key" {
  description = "Secret access key for the Minecraft restic backup user. Copy into the SOPS secret."
  value       = aws_iam_access_key.minecraft_backup.secret
  sensitive   = true
}

output "cnpg_access_key_ids" {
  description = "Access key IDs for the per-app CloudNativePG backup users. Copy into each app's SOPS secret."
  value       = { for k, v in aws_iam_access_key.cnpg : k => v.id }
  sensitive   = true
}

output "cnpg_secret_access_keys" {
  description = "Secret access keys for the per-app CloudNativePG backup users. Copy into each app's SOPS secret."
  value       = { for k, v in aws_iam_access_key.cnpg : k => v.secret }
  sensitive   = true
}
