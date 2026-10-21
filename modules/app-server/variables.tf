variable "name_prefix" {
  type    = string
  default = "collective"
}

variable "environment" {
  description = "uat | prod"
  type        = string
  validation {
    condition     = contains(["uat", "prod"], var.environment)
    error_message = "environment must be uat or prod"
  }
}

variable "region" {
  type = string
}

variable "instance_type" {
  description = "Graviton instance type (arm64). t4g.large for UAT, t4g.xlarge for prod."
  type        = string
  validation {
    condition     = can(regex("^(t4g|m7g|m8g|c7g|r7g|r8g)\\.", var.instance_type))
    error_message = "Use an arm64 (Graviton) instance type — the AMI and images are arm64."
  }
}

variable "cpu_credits" {
  description = "standard | unlimited (T-family only)"
  type        = string
  default     = "standard"
}

variable "subnet_id" {
  type = string
}

variable "availability_zone" {
  description = "Must match the subnet's AZ; the data EBS volume is created here"
  type        = string
}

variable "security_group_id" {
  type = string
}

variable "root_volume_size_gb" {
  type    = number
  default = 30
}

variable "data_volume_size_gb" {
  type = number
}

variable "backup_bucket_name" {
  type = string
}

variable "backup_bucket_arn" {
  type = string
}

variable "secrets_prefix" {
  description = "Secrets Manager name prefix, e.g. collective/uat"
  type        = string
}

variable "extra_policy_arns" {
  description = "Per-product IAM policies (S3/Secrets/SES) to attach to the instance role"
  type        = list(string)
  default     = []
}

variable "github_org" {
  type = string
}

variable "infra_repo" {
  type    = string
  default = "collective-infra"
}

variable "infra_branch" {
  description = "Branch of collective-infra the box tracks for platform/ files"
  type        = string
  default     = "main"
}

variable "compose_version" {
  description = "docker compose plugin release installed by user-data"
  type        = string
  default     = "v2.40.0"
}

variable "platform_hostname" {
  description = "Hostname for platform endpoints (EMQX dashboard, health) e.g. platform-uat.getpack.co"
  type        = string
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "enable_instance_check_reboot" {
  description = "Auto-reboot on instance status check failure (disable where the box is stopped by schedule)"
  type        = bool
  default     = true
}

variable "cpu_credit_threshold" {
  type    = number
  default = 50
}

variable "memory_alarm_percent" {
  type    = number
  default = 90
}

variable "disk_alarm_percent" {
  type    = number
  default = 80
}

variable "snapshot_time_utc" {
  type    = string
  default = "19:00"
}

variable "snapshot_retention_count" {
  type    = number
  default = 7
}

variable "snapshot_copy_region" {
  description = "Region that receives an encrypted copy of every daily data-volume snapshot (DLM cross-region copy); null = no copy"
  type        = string
  default     = null
  validation {
    condition     = var.snapshot_copy_region == null || can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.snapshot_copy_region))
    error_message = "snapshot_copy_region must be an AWS region code such as ap-northeast-1"
  }
}

variable "snapshot_copy_retention_days" {
  description = "Days the cross-region snapshot copies are kept"
  type        = number
  default     = 7
}

variable "snapshot_copy_kms_key_arn" {
  description = "KMS key in snapshot_copy_region for the copies (null = that region's default EBS key)"
  type        = string
  default     = null
}
