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
  description = "getpack | getproperty | getbuild"
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

variable "ses_region" {
  description = "Region of the aliased aws.ses provider (SES is not available in ap-southeast-7)"
  type        = string
  default     = "ap-southeast-1"
}
