# collective-infra

Infrastructure-as-code for Collective Group (Thailand): **Terraform** for AWS (`ap-southeast-7`), the
**docker-compose platform** that runs on each environment's EC2 box, and the **reusable GitHub Actions**
that product repos (getpack, getproperty, getpop) call to build and deploy.

Read `PLAN.md` first — it records the decisions and the rollout phases. This file is the how-to.

```
AWS account (Thailand region)
├── envs/global   ECR repos · Budgets
├── envs/uat      VPC · EC2 t4g.large (08:00–20:00 Mon–Fri) · EIP · EBS /data · S3 · Secrets · SES · deploy role
└── envs/prod     VPC · EC2 t4g.xlarge (24×7)                · EIP · EBS /data · S3 · Secrets · SES · deploy role

each EC2 box (/opt/collective/infra = this repo)
└── platform/     caddy · postgres(timescaledb-ha pg18) · valkey · emqx · alloy  +  products/<p>/docker-compose.yml
```

## 1. Prerequisites

- Terraform ≥ 1.10, AWS CLI v2, an AWS profile with admin on the Collective account
- Region **Asia Pacific (Thailand)** enabled: Account → AWS Regions → enable `ap-southeast-7`
- GitHub org with repos `collective-infra`, `getpack-api`, `getpack-web`, `getproperty-api`, `getproperty-web`, `getpop-api`

## 2. Bootstrap (once)

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # set github_org
terraform init && terraform apply
terraform output -raw backend_hcl > ../envs/backend.hcl
terraform output gha_terraform_role_arn        # → GitHub repo variable AWS_TERRAFORM_ROLE_ARN
terraform output state_bucket                  # → GitHub repo variable TF_STATE_BUCKET
```

Keep `bootstrap/terraform.tfstate` somewhere safe (it is gitignored). Then in GitHub → Settings → Environments
create `terraform-plan`, `terraform-apply` (no reviewers) and `terraform-prod` (**required reviewer: you**).

## 3. Apply environments

```bash
make init  ENV=global && make apply ENV=global
make init  ENV=uat    && make plan ENV=uat && make apply ENV=uat
make init  ENV=prod   && make plan ENV=prod && make apply ENV=prod
```

After `apply` of an env, do these by hand (one time each):

1. **Secrets** — fill every shell Terraform created (`terraform output platform_secret_names product_secret_names`):

   | Secret | JSON |
   |---|---|
   | `collective/<env>/platform/deploy-key` | *raw* private key (read-only GitHub deploy key for this repo) |
   | `collective/<env>/platform/postgres` | `{"superuser_password":"…","getpack_password":"…","getproperty_password":"…","getpop_password":"…"}` |
   | `collective/<env>/platform/valkey` | `{"password":"…"}` |
   | `collective/<env>/platform/emqx` | `{"dashboard_password":"…"}` |
   | `collective/<env>/platform/grafana` | `{"prometheus_url":"https://prometheus-….grafana.net/api/prom/push","prometheus_user":"123","loki_url":"https://logs-….grafana.net/loki/api/v1/push","loki_user":"456","tempo_url":"https://tempo-….grafana.net/otlp","tempo_user":"789","api_key":"glc_…"}` |
   | `collective/<env>/platform/caddy` | `{"acme_email":"ops@…","basic_auth_users":["ops:$2a$14$…"]}` (`caddy hash-password`) |
   | `collective/<env>/<product>/app` | flat JSON of the product's env — `DATABASE_URL`, `REDIS_URL`, JWT keys, 3rd-party keys. Hostnames inside the docker network: `postgres`, `valkey`, `platform-emqx-1`, `platform-alloy-1` |
   | `collective/<env>/getproperty/web`, `…/getproperty/liff` | flat JSON of each front end's own env (session secrets, LIFF id, public URLs) → `/run/collective/getproperty-<web\|liff>.env` — the front ends never get the API's secrets |
   | `collective/<env>/getproperty/mqtt-tls` | `{"server_pem","server_key","ca_pem"}` — EMQX's 8883 device listener (mutual TLS): server certificate issued from getproperty's device CA (`pnpm device:broker-cert --host <MQTT_HOST>` in getproperty-api) and the CA that verifies gateways. `products/getproperty/hooks/post-secrets.sh` installs it and the Caddy device-host trust pool |

   getproperty also needs `getproperty_mqtt_password` in `collective/<env>/platform/postgres` (EMQX's read-only
   login for `smart.mqtt_acl`, created by `postgres/init/20-getproperty.sh`) and `MQTT_USERNAME` / `MQTT_PASSWORD` in
   its app secret (the API's user on EMQX's internal listener). The full key list of `getproperty/app` is in
   getproperty-api `docs/deployment.md` §3.

   **Release artefacts** (getproperty-edge OTA, getproperty-api D-231): products with `release_prefixes` (getproperty:
   `releases/`) keep signed binaries in their assets bucket under that prefix. The instance role can only read there
   (explicit deny on put/delete); attach the `release_publisher_policy_arns` output (`collective-<env>-getproperty-
   release-publisher`) to the release engineer's identity, never to the instance role or a deploy role. Gateways
   download through the API on the device host (Caddy route `/v1/device/ota/artifacts/*`), never from S3 directly.

   ```bash
   aws secretsmanager put-secret-value --secret-id collective/uat/platform/valkey --secret-string '{"password":"'"$(openssl rand -hex 24)"'"}'
   ```
   `DATABASE_URL` pattern: `postgresql://getpack:<getpack_password>@postgres:5432/getpack?schema=public&connection_limit=15`

2. **DNS** — `terraform output public_ip` → A records for every host in `platform/caddy/sites.<env>.yml` and
   `platform_hostname`. `terraform output ses_dns_records` → DKIM/MX/TXT at the registrar (automatic if `route53_zone_id` set).
3. **Box bootstrap** — user-data runs automatically. If secrets were created *after* the instance booted:
   ```bash
   aws ssm start-session --target $(terraform output -raw instance_id)
   sudo bash /var/lib/cloud/instance/scripts/part-001      # re-run user-data (idempotent)
   sudo journalctl -u collective-platform -f
   ```
4. **GitHub Environments** `uat` and `production` (in *each* product repo and in this repo):
   variables `AWS_DEPLOY_ROLE_ARN` (= `terraform output deploy_role_arn`), `INSTANCE_ID`, `AWS_REGION=ap-southeast-7`;
   `production` gets a required reviewer.
5. **SES** — request production access (out of sandbox) per account once; identities are verified by DKIM.

## 4. Product repo wiring

Each product repo adds **one** workflow next to its existing `ci.yml` / `release.yml`:

```yaml
# .github/workflows/deploy.yml  (getpack-api example)
name: Deploy
on:
  push: { branches: [main] }        # → UAT
  push: { tags: ["v*.*.*"] }        # → production (after approval)   ← merge into one `on:` block
permissions: { id-token: write, contents: read, packages: read }

jobs:
  build-uat:
    if: github.ref == 'refs/heads/main'
    uses: <org>/collective-infra/.github/workflows/reusable-build-push.yml@v1
    with: { image: getpack/api, environment: uat, moving_tag: uat }
  deploy-uat:
    needs: build-uat
    uses: <org>/collective-infra/.github/workflows/reusable-deploy.yml@v1
    with: { product: getpack, environment: uat, image_tag: ${{ needs.build-uat.outputs.image_tag }} }

  build-prod:
    if: startsWith(github.ref, 'refs/tags/v')
    uses: <org>/collective-infra/.github/workflows/reusable-build-push.yml@v1
    with: { image: getpack/api, environment: production, moving_tag: prod }
  deploy-prod:
    needs: build-prod
    uses: <org>/collective-infra/.github/workflows/reusable-deploy.yml@v1
    with: { product: getpack, environment: production, image_tag: ${{ needs.build-prod.outputs.image_tag }} }
```

Notes
- A product with two images (api + web) must push **both** with the same `image_tag` before `reusable-deploy`
  runs — either one monorepo workflow, or the web repo deploys with `migrate: false` after api.
- Alternative to rebuilding on tag: `promote.yml` (manual) re-tags the sha that passed UAT as `:prod`.
- Tag `v1` of this repo = the reusable-workflow API. Bump deliberately.
- **Multi-repo products** (getproperty: `getproperty-api`, `getproperty-web`, `getproperty-liff`): the api repo deploys
  `IMAGE_TAG` (api, worker, ingest, migrate); each front-end repo deploys its own image with `component: web` /
  `component: liff` on `reusable-deploy.yml` (→ `deploy-product.sh … --component web`, state `WEB_IMAGE_TAG`, no
  migration, rollback of that image only). Until a front end's first deploy the box runs its moving `:uat` / `:prod`
  tag. The image must exist in ECR before the first `deploy-product.sh getproperty` (compose pulls every service).
- A build that needs a sibling source tree (getproperty-api builds `@collective/asset-core` from source until the
  package is on GitHub Packages) passes `extra_repository` / `extra_ref` / `extra_path` / `build_contexts` and the
  `extra_repository_token` secret to `reusable-build-push.yml`.
- Contract the compose templates expect from images: `/health` on `:3000` (api), `/api/healthz` on `:3000` (web),
  worker health on `:3001`, Prometheus `/metrics`, OTLP to `$OTEL_EXPORTER_OTLP_ENDPOINT`.
  Migration = the product compose file's one-shot `migrate` service (getpack: `npx prisma migrate deploy`;
  getproperty: `node dist/src/migrate.js` — asset-core `core` schema first, then its Prisma migrations, then the
  optional TimescaleDB step).

## 5. Day-2 operations

| Task | How |
|---|---|
| Shell on a box | `aws ssm start-session --target <instance-id>` (no SSH, no keys) |
| Logs / metrics | Grafana Cloud (labels `env`, `product`, `service`, `level`); host alarms → SNS email |
| Deploy status | GitHub Actions run → SSM output; on the box `/var/log/collective/platform.log` |
| Roll back | `sudo /opt/collective/platform/bin/rollback.sh <product>` (deploy also auto-rolls back on failed health) |
| Backups | nightly 01:30 pgBackRest (full Sun / diff) → `s3://collective-<env>-backups/pgbackrest/<env>`; EBS snapshot 02:00 (DLM) |
| Verify backups | `docker exec platform-postgres-1 pgbackrest --stanza=collective info` |
| **Restore drill (monthly)** | on UAT: `sudo /opt/collective/platform/bin/restore-drill.sh prod` → report in `s3://…-backups/drills/` |
| PITR | `restore-drill.sh prod --pitr "2026-11-01 02:00:00+07"` to inspect; real restore = stop products, same `pgbackrest restore` into `/data/postgres` |
| Wake UAT off-hours | `platform/bin/wake.sh uat` (stops again at 20:00) |
| Change hostnames | edit `platform/caddy/sites.<env>.yml` → PR → `platform-deploy.yml` |
| Resize box | change `instance_type` in `envs/<env>/terraform.tfvars` → PR (stop/start, ~3 min downtime) |
| Grow /data | bump `data_volume_size_gb` → apply → on box `sudo xfs_growfs /data` |
| Rotate a secret | update Secrets Manager → `secrets-refresh.timer` renders hourly → next deploy picks it up (or `deploy-product.sh <p> <same-tag>`) |
| Peel a product to RDS | `pg_dump` its database → RDS; change only that product's `DATABASE_URL` secret; nothing else moves |

## 6. Conventions

- `terraform fmt -recursive` before commit; CI enforces it.
- Never `terraform apply` prod from a laptop once CI works — use the PR → approval path.
- `prevent_destroy` guards the data volume, backup bucket and asset buckets. Removing it is a reviewed PR.
- No secrets in this repo, in tfvars, or in GitHub secrets: Secrets Manager is the only store; CI uses OIDC roles.
