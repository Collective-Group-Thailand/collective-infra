# UAT — t4g.large, office hours only (Mon–Fri 08:00–20:00 Asia/Bangkok)

vpc_cidr                 = "10.20.0.0/16"
instance_type            = "t4g.large"
data_volume_size_gb      = 60
snapshot_retention_count = 3
platform_hostname        = "platform-uat.getpack.co" # TODO: or a collective-group domain

alert_emails  = ["piyapan.pak@gmail.com"] # TODO
github_org_id = 346483067
github_org    = "Collective-Group-Thailand" # TODO: real org

product_repos = [
  "getpack-api", "getpack-web",
  "getproperty-api", "getproperty-web", "getproperty-liff",
  "getbuild-api",
]

ecr_repositories = [
  "getpack/api", "getpack/web",
  "getproperty/api", "getproperty/web", "getproperty/liff",
  "getbuild/api",
]

products = {
  getpack = {
    cors_origins = ["https://uat.getpack.co"]
    ses_domain   = "uat.getpack.co"
    # route53_zone_id = "Z..."      # set when the zone lives in this account
    # getpack's worker consumes the shared pdf-render queue (the one Chromium per box): S3 Get/Put on
    # collective-<env>-getproperty-assets/tmp/pdf-render/* only (getproperty-api docs/pdf-render-queue.md §6.4)
    pdf_render_producers = ["getproperty"]
  }
  getproperty = {
    # browser uploads (presigned PUT) from the owner console, staff PWA, admin and the LIFF app
    cors_origins = ["https://uat-app.getproperty.app", "https://uat-staff.getproperty.app", "https://uat-admin.getproperty.app", "https://uat-liff.getproperty.app"]
    ses_domain   = "uat.getproperty.app" # SES_FROM_ADDRESS getproperty <no-reply@uat.getproperty.app>
    # one secret collective/<env>/getproperty/app; front-end keys prefixed WEB__ / LIFF__ (T-4, README §3)
    # signed OTA artefacts of getproperty-edge (releases/edge/<version>/<file>): read-only for the instance role,
    # uploaded with the release-publisher policy (getproperty-api docs/deployment.md §5a, D-231)
    release_prefixes = ["releases/"]
    # tmp/pdf-render/ scratch objects of the shared pdf-render queue (HTML in, PDF out — personal data): 1 day
    # (getproperty-api docs/pdf-render-queue.md §3)
    tmp_expiration_days = 1
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
