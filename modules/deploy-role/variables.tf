variable "name" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "github_org" {
  type = string
}

variable "github_org_id" {
  description = "Numeric GitHub org id. Set when the org issues immutable OIDC subjects (repo:<org>@<id>/<repo>@<repo-id>:…)"
  type        = number
  default     = null
}

variable "github_repos" {
  description = "Repos allowed to deploy to this environment (product repos + collective-infra)"
  type        = list(string)
}

variable "github_environment" {
  description = "GitHub Environment name the workflow must run in (uat | production)"
  type        = string
}

variable "github_oidc_provider_arn" {
  type = string
}

variable "ecr_repository_arns" {
  type = list(string)
}

variable "instance_arn" {
  type = string
}

variable "allow_start_instance" {
  description = "Let deploys start a stopped (scheduled) box"
  type        = bool
  default     = false
}
