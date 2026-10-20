variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "enable_mqtt" {
  description = "Open 8883 for EMQX (getproperty IoT edge devices)"
  type        = bool
  default     = true
}
