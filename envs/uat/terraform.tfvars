# UAT — t4g.large, office hours only (Mon–Fri 08:00–20:00 Asia/Bangkok)

vpc_cidr                 = "10.20.0.0/16"
instance_type            = "t4g.large"
data_volume_size_gb      = 60
snapshot_retention_count = 3
platform_hostname        = "platform-uat.getpack.co" # TODO: or a collective-group domain

alert_emails = ["piyapan.pak@gmail.com"]         # TODO
github_org   = "Collective-Group-Thailand" # TODO: real org

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
    cors_origins = ["https://uat.getpack.co"]
    ses_domain   = "uat.getpack.co"
    # route53_zone_id = "Z..."      # set when the zone lives in this account
  }
  getproperty = {
    cors_origins = ["https://uat.getproperty.example"] # TODO domain
    ses_domain   = null                                # enable when the domain is decided
  }
  getbuild = {
    cors_origins = ["https://uat.getbuild.example"] # TODO domain
    ses_domain   = null
  }
}

schedule = {
  enabled    = true
  timezone   = "Asia/Bangkok"
  start_cron = "0 8 ? * MON-FRI *"
  stop_cron  = "0 20 ? * MON-FRI *"
}
