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

variable "snapshot_copy_region" {
  description = "DLM cross-region copy target of the daily data-volume snapshot (null = none)"
  type        = string
  default     = null
}

variable "snapshot_copy_retention_days" {
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
  # tmp_expiration_days: lifecycle expiry of tmp/ (getproperty 1 — pdf-render scratch objects with personal data);
  # pdf_render_producers: products whose pdf-render jobs this product consumes (getpack: ["getproperty"]).
  description = "Products hosted in this environment"
  type = map(object({
    cors_origins         = optional(list(string), [])
    ses_domain           = optional(string)
    route53_zone_id      = optional(string)
    enable_sqs           = optional(bool, false)
    release_prefixes     = optional(list(string), [])
    tmp_expiration_days  = optional(number, 7)
    pdf_render_producers = optional(list(string), [])
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
