# Production — t4g.xlarge, 24×7, 3 products on one box (PLAN.md §0)

vpc_cidr                 = "10.10.0.0/16"
instance_type            = "t4g.xlarge"
cpu_credits              = "standard" # switch to m7g.xlarge instead of "unlimited" if the credit alarm fires often
data_volume_size_gb      = 120
snapshot_retention_count = 7
platform_hostname        = "platform.getpack.co" # TODO: or a collective-group domain

alert_emails = ["ops@collective.example"] # TODO
github_org   = "collective-group-th"      # TODO: real org

product_repos = [
  "getpack-api", "getpack-web",
  "getproperty-api", "getproperty-web",
  "getbuild-api",
]

ecr_repositories = [
  "getpack/api", "getpack/web",
  "getproperty/api", "getproperty/web",
  "getbuild/api",
]

products = {
  getpack = {
    cors_origins = ["https://getpack.co", "https://www.getpack.co"]
    ses_domain   = "getpack.co"
    # route53_zone_id = "Z..."
  }
  getproperty = {
    cors_origins = ["https://getproperty.example"] # TODO domain
    ses_domain   = null
  }
  getbuild = {
    cors_origins = ["https://getbuild.example"] # TODO domain
    ses_domain   = null
  }
}

schedule = {
  enabled = false
}
