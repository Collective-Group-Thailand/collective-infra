variable "region" {
  type    = string
  default = "ap-southeast-7"
}

variable "ecr_repositories" {
  type = list(string)
  default = [
    "getpack/api",
    "getpack/web",
    "getproperty/api",
    "getproperty/web",
    "getpop/api",
  ]
}

variable "monthly_budget_usd" {
  type    = number
  default = 300
}

variable "alert_emails" {
  type = list(string)
}
