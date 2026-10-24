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

variable "release_prefixes" {
  description = "Bucket prefixes holding signed release artefacts (e.g. getproperty \"releases/\"): the instance role may only read them; writes need the separate release-publisher policy"
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for p in var.release_prefixes : can(regex("^[a-z0-9][a-z0-9-]*/$", p)) && p != "tmp/"])
    error_message = "release_prefixes are top-level prefixes ending in / (not tmp/)"
  }
}

variable "tmp_expiration_days" {
  description = "Lifecycle expiry (current and noncurrent versions) of objects under tmp/ in the assets bucket"
  type        = number
  default     = 7
  validation {
    condition     = var.tmp_expiration_days >= 1 && var.tmp_expiration_days <= 30 && floor(var.tmp_expiration_days) == var.tmp_expiration_days
    error_message = "tmp_expiration_days is a whole number of days, 1-30"
  }
}

variable "pdf_render_producers" {
  description = "Products whose shared pdf-render jobs this product consumes (getpack's worker): s3:GetObject + s3:PutObject on collective-<env>-<producer>-assets/tmp/pdf-render/* only"
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for p in var.pdf_render_producers : can(regex("^[a-z][a-z0-9-]{2,20}$", p))])
    error_message = "pdf_render_producers are product slugs"
  }
}
