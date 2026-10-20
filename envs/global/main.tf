# Account-wide, environment-independent resources: ECR repos, cost budget.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    key = "global/terraform.tfstate"
    # bucket/region/use_lockfile come from ../backend.hcl (terraform init -backend-config=../backend.hcl)
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "collective-platform"
      ManagedBy = "terraform"
      Root      = "global"
    }
  }
}

module "ecr" {
  source       = "../../modules/ecr"
  repositories = var.ecr_repositories
}

# --- Cost guard-rail -------------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "collective-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_emails
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.alert_emails
  }
}
