# Production — t4g.xlarge, 24×7, 3 products on one box (PLAN.md §0)

vpc_cidr                 = "10.10.0.0/16"
instance_type            = "t4g.xlarge"
cpu_credits              = "standard" # switch to m7g.xlarge instead of "unlimited" if the credit alarm fires often
data_volume_size_gb      = 120
snapshot_retention_count = 7

# DLM cross-region copy of the daily /data snapshot (locked decision 6; getproperty O-016, 2026-10-21): Tokyo — outside
# Singapore (locked decision 1), a destination with a comprehensive data-protection law (APPI) for the PDPA s.28
# cross-border basis; copies encrypted, kept 7 days. PLAN.md §0 "Backup" holds the PDPA note; legal sign-off of the
# processor (AWS) DPA wording is tracked in getproperty-api O-016.
snapshot_copy_region         = "ap-northeast-1"
snapshot_copy_retention_days = 7

platform_hostname = "platform.getpack.co" # TODO: or a collective-group domain

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
    cors_origins = ["https://getpack.co", "https://www.getpack.co"]
    ses_domain   = "getpack.co"
    # route53_zone_id = "Z..."
  }
  getproperty = {
    # browser uploads (presigned PUT) from the owner console, staff PWA, admin and the LIFF app — TODO domain
    cors_origins = ["https://app.getproperty.example", "https://staff.getproperty.example", "https://admin.getproperty.example", "https://liff.getproperty.example"]
    ses_domain   = null # enable when the domain is decided (SES_FROM_ADDRESS no-reply@<domain>)
    # one secret collective/<env>/getproperty/app; front-end keys prefixed WEB__ / LIFF__ (T-4, README §3)
    # signed OTA artefacts of getproperty-edge (releases/edge/<version>/<file>): read-only for the instance role,
    # uploaded with the release-publisher policy (getproperty-api docs/deployment.md §5a, D-231)
    release_prefixes = ["releases/"]
  }
  getpop = {
    cors_origins = ["https://getpop.example"] # TODO domain
    ses_domain   = null
  }
}

schedule = {
  enabled = false
}
