# UAT — t4g.large, office hours only (Mon–Fri 08:00–20:00 Asia/Bangkok)

vpc_cidr                 = "10.20.0.0/16"
instance_type            = "t4g.large"
data_volume_size_gb      = 60
snapshot_retention_count = 3
platform_hostname        = "platform-uat.getpack.co" # TODO: or a collective-group domain

alert_emails = ["ops@collective.example"] # TODO
github_org   = "collective-group-th"      # TODO: real org

product_repos = [
  "getpack-api", "getpack-web",
  "getproperty-api", "getproperty-web", "getproperty-liff",
  "getpop-api",
]

ecr_repositories = [
  "getpack/api", "getpack/web",
  "getproperty/api", "getproperty/web", "getproperty/liff",
  "getpop/api",
]

products = {
  getpack = {
    cors_origins = ["https://uat.getpack.co"]
    ses_domain   = "uat.getpack.co"
    # route53_zone_id = "Z..."      # set when the zone lives in this account
  }
  getproperty = {
    # browser uploads (presigned PUT) from the owner console, staff PWA, admin and the LIFF app — TODO domain
    cors_origins = ["https://uat-app.getproperty.example", "https://uat-staff.getproperty.example", "https://uat-admin.getproperty.example", "https://uat-liff.getproperty.example"]
    ses_domain   = null # enable when the domain is decided (SES_FROM_ADDRESS no-reply@<domain>)
    # front-end env files and the EMQX device-listener TLS (getproperty-api docs/deployment.md §3)
    extra_secrets = ["web", "liff", "mqtt-tls"]
  }
  getpop = {
    cors_origins = ["https://uat.getpop.example"] # TODO domain
    ses_domain   = null
  }
}

schedule = {
  enabled    = true
  timezone   = "Asia/Bangkok"
  start_cron = "0 8 ? * MON-FRI *"
  stop_cron  = "0 20 ? * MON-FRI *"
}
