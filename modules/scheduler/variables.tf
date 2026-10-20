variable "name" {
  type = string
}

variable "instance_id" {
  type = string
}

variable "instance_arn" {
  type = string
}

variable "enabled" {
  type    = bool
  default = true
}

variable "timezone" {
  type    = string
  default = "Asia/Bangkok"
}

variable "start_cron" {
  description = "EventBridge 6-field cron (min hour dom month dow year)"
  type        = string
  default     = "0 8 ? * MON-FRI *"
}

variable "stop_cron" {
  type    = string
  default = "0 20 ? * MON-FRI *"
}
