variable "region" {
  type    = string
  default = "ap-southeast-7"
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

variable "infra_branch" {
  type    = string
  default = "main"
}

variable "product_repos" {
  type = list(string)
}

variable "ecr_repositories" {
  type = list(string)
}

# release_prefixes must be listed here too, or the type conversion drops them from terraform.tfvars
variable "products" {
  type = map(object({
    cors_origins     = optional(list(string), [])
    ses_domain       = optional(string)
    route53_zone_id  = optional(string)
    enable_sqs       = optional(bool, false)
    release_prefixes = optional(list(string), [])
  }))
}

variable "schedule" {
  type = object({
    enabled    = bool
    timezone   = optional(string, "Asia/Bangkok")
    start_cron = optional(string, "0 8 ? * MON-FRI *")
    stop_cron  = optional(string, "0 20 ? * MON-FRI *")
  })
}
