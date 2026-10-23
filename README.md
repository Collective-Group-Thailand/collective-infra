# collective-infra

Infrastructure-as-code for Collective Group (Thailand): **Terraform** for AWS (`ap-southeast-7`), the
**docker-compose platform** that runs on each environment's EC2 box, and the **reusable GitHub Actions**
that product repos (getpack, getproperty, getbuild) call to build and deploy.

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
- GitHub org with repos `collective-infra`, `getpack-api`, `getpack-web`, `getproperty-api`, `getproperty-web`, `getbuild-api`

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
   | `collective/<env>/platform/postgres` | `{"superuser_password":"…","getpack_password":"…","getproperty_password":"…","getbuild_password":"…"}` |
   | `collective/<env>/platform/valkey` | `{"password":"…"}` |
   | `collective/<env>/platform/emqx` | `{"dashboard_password":"…"}` |
   | `collective/<env>/platform/grafana` | `{"prometheus_url":"https://prometheus-….grafana.net/api/prom/push","prometheus_user":"123","loki_url":"https://logs-….grafana.net/loki/api/v1/push","loki_user":"456","tempo_url":"https://tempo-….grafana.net/otlp","tempo_user":"789","api_key":"glc_…"}` |
   | `collective/<env>/platform/caddy` | `{"acme_email":"ops@…","basic_auth_users":["ops:$2a$14$…"]}` (`caddy hash-password`) |
   | `collective/<env>/<product>/app` | flat JSON of the product's env — `DATABASE_URL`, `REDIS_URL`, JWT keys, 3rd-party keys. Hostnames inside the docker network: `postgres`, `valkey`, `platform-emqx-1`, `platform-alloy-1` |

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
# getpack-api/.github/workflows/deploy.yml (getpack-web is the same with image getpack/web, component web)
name: Deploy
on:
  workflow_run: { workflows: [CI], types: [completed], branches: [main] }   # → UAT, only after CI is green
  workflow_dispatch:
permissions: { id-token: write, contents: read, packages: read }

jobs:
  build:
    if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'
    uses: Collective-Group-Thailand/collective-infra/.github/workflows/reusable-build-push.yml@v1
    with:
      image: getpack/api
      environment: uat
      moving_tag: uat
      ref: ${{ github.event.workflow_run.head_sha || github.sha }}
  deploy:
    needs: build
    uses: Collective-Group-Thailand/collective-infra/.github/workflows/reusable-deploy.yml@v1
    with: { product: getpack, component: api, environment: uat, image_tag: "${{ needs.build.outputs.image_tag }}" }
```

Notes
- **Each image deploys on its own** (`component` = `api` | `web`): the box keeps `API_TAG` / `WEB_TAG` per product in
  `/var/lib/collective/<product>.env`, and rollback is per component. api deploys run migrations first.
- Production: `promote.yml` (manual, `production` environment approval) re-tags the api sha that passed UAT as `:prod`.
  Web bakes `NEXT_PUBLIC_*` at build time, so production web is built from a release tag with production build args.
- The private `collective-infra` repo must allow reuse: Settings → Actions → General → Access →
  *Accessible from repositories in the organization*.
- Tag `v1` of this repo = the reusable-workflow API. Move it deliberately (`git tag -f v1 && git push -f origin v1`).
- Contract the compose templates expect from images: api `/health` on `:3000`; web answers on `:3000` (any non-5xx);
  worker has no HTTP port; OTLP to `$OTEL_EXPORTER_OTLP_ENDPOINT`.
  Migration = `/opt/prisma-cli/node_modules/.bin/prisma migrate deploy` inside the api image.

## 5. Day-2 operations

| Task | How |
|---|---|
| Shell on a box | `aws ssm start-session --target <instance-id>` (no SSH, no keys) |
| Logs / metrics | Grafana Cloud (labels `env`, `product`, `service`, `level`); host alarms → SNS email |
| Deploy status | GitHub Actions run → SSM output; on the box `/var/log/collective/platform.log` |
| Roll back | `sudo /opt/collective/platform/bin/rollback.sh <product> <api|web>` (deploy also auto-rolls back on failed health) |
| Backups | nightly 01:30 pgBackRest (full Sun / diff) → `s3://collective-<env>-backups/pgbackrest/<env>`; EBS snapshot 02:00 (DLM) |
| Verify backups | `docker exec platform-postgres-1 pgbackrest --stanza=collective info` |
| **Restore drill (monthly)** | on UAT: `sudo /opt/collective/platform/bin/restore-drill.sh prod` → report in `s3://…-backups/drills/` |
| PITR | `restore-drill.sh prod --pitr "2026-11-01 02:00:00+07"` to inspect; real restore = stop products, same `pgbackrest restore` into `/data/postgres` |
| Wake UAT off-hours | `platform/bin/wake.sh uat` (stops again at 20:00) |
| Change hostnames | edit `platform/caddy/sites.<env>.yml` → PR → `platform-deploy.yml` |
| Resize box | change `instance_type` in `envs/<env>/terraform.tfvars` → PR (stop/start, ~3 min downtime) |
| Grow /data | bump `data_volume_size_gb` → apply → on box `sudo xfs_growfs /data` |
| Rotate a secret | update Secrets Manager → `secrets-refresh.timer` renders hourly → next deploy picks it up (or `deploy-product.sh <p> <component> <same-tag>`) |
| Peel a product to RDS | `pg_dump` its database → RDS; change only that product's `DATABASE_URL` secret; nothing else moves |

## 6. Conventions

- `terraform fmt -recursive` before commit; CI enforces it.
- Never `terraform apply` prod from a laptop once CI works — use the PR → approval path.
- `prevent_destroy` guards the data volume, backup bucket and asset buckets. Removing it is a reviewed PR.
- No secrets in this repo, in tfvars, or in GitHub secrets: Secrets Manager is the only store; CI uses OIDC roles.
