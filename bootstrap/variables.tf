variable "region" {
  description = "Region for the state bucket. Thailand is an opt-in region — enable it in the account first."
  type        = string
  default     = "ap-southeast-7"
}

variable "name_prefix" {
  type    = string
  default = "collective"
}

variable "github_org" {
  description = "GitHub organisation that owns collective-infra and the product repos"
  type        = string
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
