# One complete environment (uat or prod). Called from envs/uat and envs/prod so both stay identical
# in shape and differ only in variables.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name           = "${var.name_prefix}-${var.environment}"
  secrets_prefix = "${var.name_prefix}/${var.environment}"
  oidc_arn       = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
  github_env     = var.environment == "prod" ? "production" : var.environment
}

# --- Network ---------------------------------------------------------------------------------------
module "network" {
  source      = "../../modules/network"
  name        = local.name
  region      = var.region
  cidr        = var.vpc_cidr
  enable_mqtt = contains(keys(var.products), "getproperty")
}

data "aws_subnet" "primary" {
  id = module.network.public_subnet_ids[0]
}

# --- Backup bucket (pgBackRest repo + restore drills) ----------------------------------------------
resource "aws_s3_bucket" "backups" {
  bucket = "${local.name}-backups"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
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
  # pgBackRest manages its own retention (repo-retention-full); these rules are the safety net.
  rule {
    id     = "noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 2
    }
  }
  rule {
    id     = "drill-exports"
    status = "Enabled"
    filter {
      prefix = "drills/"
    }
    expiration {
      days = 14
    }
  }
}

# --- Platform-level secrets (shells) ---------------------------------------------------------------
resource "aws_secretsmanager_secret" "platform" {
  for_each = toset([
    "deploy-key", # read-only GitHub deploy key (private key) for collective-infra
    "postgres",   # {"superuser_password": "...", "<product>_password": "..."}
    "valkey",     # {"password": "..."}
    "emqx",       # {"dashboard_password": "...", "api_key": "...", "api_secret": "..."}
    "grafana",    # {"prometheus_url","prometheus_user","loki_url","loki_user","tempo_url","tempo_user","api_key"}
    "caddy",      # {"acme_email": "..."}
    # Device CA for IoT gateways (getproperty-api D-235): {"ca_chain_pem","issuing_cert_pem","issuing_key_pem",
    # "broker_cert_pem","broker_key_pem"} — rendered for EMQX's 8883 listener, Caddy's device host and getproperty-api
    "device-ca",
  ])
  name                    = "${local.secrets_prefix}/platform/${each.value}"
  recovery_window_in_days = var.environment == "prod" ? 30 : 7
  tags                    = { Environment = var.environment, Scope = "platform" }
}

# --- Products --------------------------------------------------------------------------------------
module "product" {
  for_each         = var.products
  source           = "../../modules/product"
  name_prefix      = var.name_prefix
  environment      = var.environment
  region           = var.region
  product          = each.key
  cors_origins     = each.value.cors_origins
  ses_domain       = each.value.ses_domain
  route53_zone_id  = each.value.route53_zone_id
  enable_sqs       = each.value.enable_sqs
  release_prefixes = each.value.release_prefixes
}

# --- App server ------------------------------------------------------------------------------------
module "app_server" {
  source                       = "../../modules/app-server"
  name_prefix                  = var.name_prefix
  environment                  = var.environment
  region                       = var.region
  instance_type                = var.instance_type
  cpu_credits                  = var.cpu_credits
  subnet_id                    = module.network.public_subnet_ids[0]
  availability_zone            = data.aws_subnet.primary.availability_zone
  security_group_id            = module.network.app_security_group_id
  root_volume_size_gb          = var.root_volume_size_gb
  data_volume_size_gb          = var.data_volume_size_gb
  backup_bucket_name           = aws_s3_bucket.backups.bucket
  backup_bucket_arn            = aws_s3_bucket.backups.arn
  secrets_prefix               = local.secrets_prefix
  extra_policy_arns            = [for p in module.product : p.policy_arn]
  github_org                   = var.github_org
  infra_repo                   = var.infra_repo
  infra_branch                 = var.infra_branch
  platform_hostname            = var.platform_hostname
  alert_emails                 = var.alert_emails
  enable_instance_check_reboot = !var.schedule.enabled
  snapshot_retention_count     = var.snapshot_retention_count
  snapshot_copy_region         = var.snapshot_copy_region
  snapshot_copy_retention_days = var.snapshot_copy_retention_days
}

# --- Office-hours schedule (UAT) -------------------------------------------------------------------
module "schedule" {
  source       = "../../modules/scheduler"
  name         = "${local.name}-app"
  instance_id  = module.app_server.instance_id
  instance_arn = module.app_server.instance_arn
  enabled      = var.schedule.enabled
  timezone     = var.schedule.timezone
  start_cron   = var.schedule.start_cron
  stop_cron    = var.schedule.stop_cron
}

# --- GitHub Actions deploy role --------------------------------------------------------------------
data "aws_ecr_repository" "images" {
  for_each = toset(var.ecr_repositories)
  name     = each.value
}

module "deploy_role" {
  source                   = "../../modules/deploy-role"
  name                     = local.name
  environment              = var.environment
  region                   = var.region
  github_org               = var.github_org
  github_repos             = concat([var.infra_repo], var.product_repos)
  github_environment       = local.github_env
  github_oidc_provider_arn = local.oidc_arn
  ecr_repository_arns      = [for r in data.aws_ecr_repository.images : r.arn]
  instance_arn             = module.app_server.instance_arn
  allow_start_instance     = var.schedule.enabled
}
