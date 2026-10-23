variable "name_prefix" {
  type    = string
  default = "collective"
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "cpu_credits" {
  type    = string
  default = "standard"
}

variable "root_volume_size_gb" {
  type    = number
  default = 30
}

variable "data_volume_size_gb" {
  type = number
}

variable "snapshot_retention_count" {
  type    = number
  default = 7
}

variable "platform_hostname" {
  type = string
}

variable "alert_emails" {
  type = list(string)
}

variable "github_org" {
  type = string
}

variable "github_org_id" {
  description = "Numeric GitHub org id. Set when the org issues immutable OIDC subjects (repo:<org>@<id>/<repo>@<repo-id>:…)"
  type        = number
  default     = null
}

variable "infra_repo" {
  type    = string
  default = "collective-infra"
}

variable "infra_branch" {
  type    = string
  default = "main"
}

variable "product_repos" {
  description = "GitHub repos (names only) allowed to deploy into this environment"
  type        = list(string)
}

variable "ecr_repositories" {
  description = "ECR repo names (created in envs/global) this env's deploy role may push to"
  type        = list(string)
}

variable "products" {
  description = "Products hosted in this environment"
  type = map(object({
    cors_origins    = optional(list(string), [])
    ses_domain      = optional(string)
    route53_zone_id = optional(string)
    enable_sqs      = optional(bool, false)
  }))
}

variable "schedule" {
  description = "Office-hours start/stop. enabled=false for prod."
  type = object({
    enabled    = bool
    timezone   = optional(string, "Asia/Bangkok")
    start_cron = optional(string, "0 8 ? * MON-FRI *")
    stop_cron  = optional(string, "0 20 ? * MON-FRI *")
  })
}

variable "ses_region" {
  type    = string
  default = "ap-southeast-1"
}
