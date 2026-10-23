# Per-product, per-environment isolation unit: S3 bucket, Secrets Manager shell, SES identity,
# and ONE IAM policy granting exactly that product's access (attached to the shared instance role).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name        = "${var.name_prefix}-${var.environment}-${var.product}"
  secret_path = "${var.name_prefix}/${var.environment}/${var.product}"
  tags = {
    Environment = var.environment
    Product     = var.product
  }
}

# --- S3: assets (artwork, uploads, generated PDFs) -----------------------------------------------
resource "aws_s3_bucket" "assets" {
  bucket = "${local.name}-assets"
  tags   = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    id     = "noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }

  rule {
    id     = "tmp-prefix-expiry"
    status = "Enabled"
    filter {
      prefix = "tmp/"
    }
    expiration {
      days = 7
    }
  }
}

# Browser direct uploads (presigned PUT) need CORS from the product's own origins
resource "aws_s3_bucket_cors_configuration" "assets" {
  count  = length(var.cors_origins) > 0 ? 1 : 0
  bucket = aws_s3_bucket.assets.id
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "HEAD"]
    allowed_origins = var.cors_origins
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

# --- Secrets Manager: shell only. Values are set by hand / rotation, never by Terraform -----------
resource "aws_secretsmanager_secret" "app" {
  name                    = "${local.secret_path}/app"
  description             = "${var.product} ${var.environment}: DATABASE_URL, REDIS_URL, JWT keys, 3rd-party API keys (JSON)"
  recovery_window_in_days = var.environment == "prod" ? 30 : 7
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "app_placeholder" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({ _placeholder = "fill in via console/CLI — see README §3" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# --- SES: sending identity ---------------------------------------------------------------------
resource "aws_sesv2_email_identity" "domain" {
  provider       = aws.ses # SES is not offered in ap-southeast-7; sends from ses_region
  count          = var.ses_domain != null ? 1 : 0
  email_identity = var.ses_domain
  tags           = local.tags
  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

resource "aws_sesv2_email_identity_mail_from_attributes" "domain" {
  provider               = aws.ses
  count                  = var.ses_domain != null ? 1 : 0
  email_identity         = aws_sesv2_email_identity.domain[0].email_identity
  mail_from_domain       = "mail.${var.ses_domain}"
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

# Optional Route 53 records (DKIM ×3, MAIL FROM MX+SPF, DMARC) when the zone is in this account
resource "aws_route53_record" "dkim" {
  count   = var.ses_domain != null && var.route53_zone_id != null ? 3 : 0
  zone_id = var.route53_zone_id
  name    = "${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.ses_domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "mail_from_mx" {
  count   = var.ses_domain != null && var.route53_zone_id != null ? 1 : 0
  zone_id = var.route53_zone_id
  name    = "mail.${var.ses_domain}"
  type    = "MX"
  ttl     = 600
  records = ["10 feedback-smtp.${var.ses_region}.amazonses.com"]
}

resource "aws_route53_record" "mail_from_spf" {
  count   = var.ses_domain != null && var.route53_zone_id != null ? 1 : 0
  zone_id = var.route53_zone_id
  name    = "mail.${var.ses_domain}"
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com -all"]
}

resource "aws_route53_record" "dmarc" {
  count   = var.ses_domain != null && var.route53_zone_id != null && var.create_dmarc ? 1 : 0
  zone_id = var.route53_zone_id
  name    = "_dmarc.${var.ses_domain}"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=quarantine; rua=mailto:dmarc@${var.ses_domain}; adkim=s; aspf=s"]
}

# --- IAM policy: everything this product's containers may touch ----------------------------------
data "aws_iam_policy_document" "product" {
  statement {
    sid       = "AssetsList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.assets.arn]
  }
  statement {
    sid       = "AssetsObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${aws_s3_bucket.assets.arn}/*"]
  }
  statement {
    sid       = "Secrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${local.secret_path}/*"]
  }

  dynamic "statement" {
    for_each = var.ses_domain != null ? [1] : []
    content {
      sid       = "SesSend"
      actions   = ["ses:SendEmail", "ses:SendRawEmail"]
      resources = [aws_sesv2_email_identity.domain[0].arn]
      condition {
        test     = "StringLike"
        variable = "ses:FromAddress"
        values   = ["*@${var.ses_domain}"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_sqs ? [1] : []
    content {
      sid       = "Sqs"
      actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ChangeMessageVisibility"]
      resources = ["arn:${data.aws_partition.current.partition}:sqs:${var.region}:${data.aws_caller_identity.current.account_id}:${local.name}-*"]
    }
  }
}

resource "aws_iam_policy" "product" {
  name        = "${local.name}-access"
  description = "Instance-role access for ${var.product} (${var.environment}): S3 assets, secrets, SES"
  policy      = data.aws_iam_policy_document.product.json
  tags        = local.tags
}
