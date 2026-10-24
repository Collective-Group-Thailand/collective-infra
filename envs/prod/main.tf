terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    key = "prod/terraform.tfstate"
    # bucket/region/use_lockfile from ../backend.hcl
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "collective-platform"
      Environment = "prod"
      ManagedBy   = "terraform"
      Root        = "prod"
    }
  }
}

# SES is not offered in ap-southeast-7 → email identities live in Singapore
provider "aws" {
  alias  = "ses"
  region = var.ses_region
  default_tags {
    tags = {
      Project     = "collective-platform"
      Environment = "prod"
      ManagedBy   = "terraform"
      Root        = "prod"
    }
  }
}

module "stack" {
  source     = "../_stack"
  providers  = { aws = aws, aws.ses = aws.ses }
  ses_region = var.ses_region

  environment                  = "prod"
  region                       = var.region
  vpc_cidr                     = var.vpc_cidr
  instance_type                = var.instance_type
  cpu_credits                  = var.cpu_credits
  data_volume_size_gb          = var.data_volume_size_gb
  snapshot_retention_count     = var.snapshot_retention_count
  snapshot_copy_region         = var.snapshot_copy_region
  snapshot_copy_retention_days = var.snapshot_copy_retention_days
  platform_hostname            = var.platform_hostname
  alert_emails                 = var.alert_emails
  github_org                   = var.github_org
  github_org_id                = var.github_org_id
  infra_branch                 = var.infra_branch
  product_repos                = var.product_repos
  ecr_repositories             = var.ecr_repositories
  products                     = var.products
  schedule                     = var.schedule
}
