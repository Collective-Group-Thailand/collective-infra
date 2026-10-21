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

variable "product" {
  description = "getpack | getproperty | getpop"
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.product))
    error_message = "product must be a short lowercase slug"
  }
}

variable "cors_origins" {
  description = "Browser origins allowed to PUT directly to the assets bucket"
  type        = list(string)
  default     = []
}

variable "noncurrent_version_days" {
  type    = number
  default = 30
}

variable "ses_domain" {
  description = "Sending domain for SES (null to skip SES)"
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "If the domain's zone is in this account, create DKIM/MAIL FROM/DMARC records"
  type        = string
  default     = null
}

variable "create_dmarc" {
  type    = bool
  default = true
}

variable "enable_sqs" {
  description = "Grant access to SQS queues named <prefix>-<env>-<product>-*"
  type        = bool
  default     = false
}

variable "extra_secrets" {
  description = "More Secrets Manager shells under <prefix>/<env>/<product>/ (e.g. per-component env files: web, liff)"
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for n in var.extra_secrets : can(regex("^[a-z][a-z0-9-]{1,30}$", n)) && n != "app"])
    error_message = "extra_secrets are short lowercase slugs (not \"app\")"
  }
}
