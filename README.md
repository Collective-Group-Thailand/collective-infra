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
└── platform/     caddy · postgres(timescaledb-ha pg18) · valkey · emqx · clamav · alloy  +  products/<p>/docker-compose.yml
```

## 1. Prerequisites

- Terraform ≥ 1.10, AWS CLI v2, an AWS profile with admin on the Collective account
- Region **Asia Pacific (Thailand)** enabled: Account → AWS Regions → enable `ap-southeast-7`
- GitHub org with repos `collective-infra`, `getpack-api`, `getpack-web`, `getproperty-api`, `getproperty-web`, `getproperty-liff`, `getpop-api`

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
   | `collective/<env>/platform/emqx` | `{"dashboard_password":"…","getproperty_auth_token":"<openssl rand -hex 32>"}` — the token is the `x-emqx-auth-token` header of EMQX's HTTP authn/authz calls to getproperty-api; the getproperty hook gives the API the same value as `EMQX_AUTH_TOKEN`. Empty = every gateway is refused |
   | `collective/<env>/platform/device-ca` | `{"ca_chain_pem","issuing_cert_pem","issuing_key_pem","broker_cert_pem","broker_key_pem"}` (PEM text) — the IoT device CA (getproperty-api D-235): the chain that verifies gateway certificates (EMQX 8883, Caddy `DEVICE_HOST`) and that gateways receive as `caChainPem`; the issuing certificate + key getproperty-api signs gateway CSRs with (rendered into its env as `DEVICE_CA_CERT` / `DEVICE_CA_KEY` / `DEVICE_CA_CHAIN`, base64); the broker server certificate for `MQTT_HOST` (leaf first + issuing, from `pnpm device:broker-cert --host <MQTT_HOST>` in getproperty-api; 397 days) used by EMQX on 8883 and by Caddy for `wss://<MQTT_HOST>/mqtt`. `bin/render-device-ca.sh` installs it (hourly refresh; the listener restarts on change) |
   | `collective/<env>/platform/grafana` | `{"prometheus_url":"https://prometheus-….grafana.net/api/prom/push","prometheus_user":"123","loki_url":"https://logs-….grafana.net/loki/api/v1/push","loki_user":"456","tempo_url":"https://tempo-….grafana.net/otlp","tempo_user":"789","api_key":"glc_…"}` |
   | `collective/<env>/platform/caddy` | `{"acme_email":"ops@…","basic_auth_users":["ops:$2a$14$…"]}` (`caddy hash-password`) |
   | `collective/<env>/<product>/app` | **the one secret of the product in that env** (locked 2026-10-21): flat JSON of the product's env — `DATABASE_URL`, `REDIS_URL`, JWT keys, 3rd-party keys. Hostnames inside the docker network: `postgres`, `valkey`, `platform-emqx-1`, `platform-clamav-1`, `platform-alloy-1`. Keys for one component only carry its prefix, `<COMPONENT>__KEY`: `fetch-secrets.sh` renders them into `/run/collective/<product>-<component>.env` with the prefix stripped and never into the main env file |
   | getproperty in `collective/<env>/getproperty/app` | API keys unprefixed (full list: getproperty-api `docs/deployment.md` §3; `MQTT_USERNAME` / `MQTT_PASSWORD` = the API's user on EMQX's internal listener; optional `EMQX_SERVICE_USERNAMES` = getproperty's users authz allows below `gp/v1/`, default `MQTT_USERNAME`; `MQTT_PUBLIC_WS_URL=wss://<MQTT_HOST>/mqtt` offers gateways the WSS fallback; `REDIS_URL` = getproperty's Valkey DB 2 — the hook adds `PDF_RENDER_REDIS_URL` = the same URL with DB 15 for `PDF_RENDERER_MODE=queue`). **Cross-product events** (D-238, D-247), per partner `P` = `GETBUILD` \| `GETPACK`: `INTEGRATION_<P>_TRANSPORT` (`none` default \| `webhook` \| `sns`), `INTEGRATION_<P>_WEBHOOK_URL` on the docker network (`http://getpop-api:3000/webhooks/integration/getproperty` for getbuild, `http://getpack-api:3000/webhooks/integration/getproperty` for getpack), `INTEGRATION_<P>_SIGNING_KEYS` (ours toward P, ≥ 32 characters, first = current), `INTEGRATION_<P>_VERIFY_KEYS` (P's keys accepted on `http://getproperty-api:3000/webhooks/integration/<getbuild\|getpack>`); Caddy keeps `/webhooks/integration/*` internal (404 on public hosts) — a partner on another box uses `sns` (SNS/SQS, D-238), never a public route. Set by the compose file / hooks, not in the secret: `EMQX_HTTP_ALLOWED_CIDRS` (the `collective` network), `EMQX_AUTH_TOKEN`, `DEVICE_CA_*`, `PDF_RENDER_QUEUE_PREFIX=collective`. **`WEB__…`** → `getproperty-web.env` and **`LIFF__…`** → `getproperty-liff.env`: each front end's own env (session secrets, hosts, public URLs; for liff `LIFF__NEXT_PUBLIC_LIFF_ID` — that environment's LINE channel —, `…NEXT_PUBLIC_VAPID_PUBLIC_KEY`, `…NEXT_PUBLIC_SENTRY_DSN`, `…NEXT_PUBLIC_ENV_BADGE`, `…NEXT_PUBLIC_ASSET_BASE_URL`). Both read every value at run time, `NEXT_PUBLIC_*` included (one image per front end for every environment, so `promote.yml` can ship the UAT image). **`MQTT_TLS__SERVER_PEM` / `__SERVER_KEY` / `__CA_PEM`**: interim only, used for EMQX's listener while `platform/device-ca` is empty. The device CA itself (`DEVICE_CA_*`) comes from `platform/device-ca` and replaces any copy here |

   **Moving from the per-component secrets** (boxes set up before T-4/T-6/T-7): copy `getproperty/web` and
   `getproperty/liff` into `getproperty/app` with the `WEB__` / `LIFF__` prefixes and `getproperty/mqtt-tls` +
   `DEVICE_CA_CERT` / `DEVICE_CA_KEY` into `platform/device-ca`, **before** `terraform apply` deletes the three shells
   (recovery window 7 days uat / 30 days prod). `getproperty_mqtt_password` in `platform/postgres` is no longer used:
   EMQX authorises gateways through getproperty-api (HTTP), and `postgres/init/20-getproperty.sh` (run it by hand once
   via SSM on such a box) drops the `getproperty_mqtt` login.

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
- Alternative to rebuilding on tag: `promote.yml` (manual) re-tags the sha that passed UAT as `:prod`. For getproperty
  pick `component` `api` / `web` / `liff` (or `all`: api with its migration, then web, then liff, each from its own
  `:uat`); a front end is promoted as its own component (`--component`, `<NAME>_IMAGE_TAG`), so the box runs exactly
  the sha UAT ran. Valid because getproperty-web and getproperty-liff compile no environment value into their images.
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
  worker-type health on `:3001` in each container (getproperty: worker **and** ingest, `INGEST_HEALTH_PORT=3001`),
  Prometheus `/metrics`, OTLP to `$OTEL_EXPORTER_OTLP_ENDPOINT`, S3 via the instance role, DB pool ≤ 15 (api) / ≤ 10
  (worker). **Migrations** = the product compose file's one-shot `migrate` service, which `deploy-product.sh` runs
  before `up` (api image only, never for `--component web|liff`):
  - getpack / getpop: `npx prisma migrate deploy`;
  - getproperty: **`node dist/src/migrate.js`** — asset-core `core` schema first, then `prisma/migrations` recorded in
    `_prisma_migrations` exactly like Prisma, then the TimescaleDB step (`TIMESCALEDB_MIGRATION`), then the
    idempotent reference seed; the image has no Prisma CLI (ADR in getproperty-api, blueprint T-3).
- **PDF rendering**: one Chromium per box — getpack's worker consumes the shared BullMQ queue **`pdf-render`** (HTML
  in → S3 key out, Thai fonts, A4 + 80 mm). The queue contract is in getproperty-api `docs/pdf-render-queue.md`
  (D-236); getpack's worker owns the consumer. Until it is deployed getproperty renders with its own Chromium under
  ADR-0012 / O-015 (worker 1.5 GB: `GETPROPERTY_PDF_RENDERER_MODE=real`, `GETPROPERTY_WORKER_MEMORY=1536M` in
  `platform/env/<env>.env`); switch both (`queue`, `512M`) when the consumer is live.
- **Upload virus scan**: the platform's shared ClamAV, `CLAMAV_HOST=platform-clamav-1`, `CLAMAV_PORT=3310` (INSTREAM,
  streams ≤ 40 MB).

## 5. Day-2 operations

| Task | How |
|---|---|
| Shell on a box | `aws ssm start-session --target <instance-id>` (no SSH, no keys) |
| Logs / metrics | Grafana Cloud (labels `env`, `product`, `service`, `level`); host alarms → SNS email |
| Deploy status | GitHub Actions run → SSM output; on the box `/var/log/collective/platform.log` |
| Roll back | `sudo /opt/collective/platform/bin/rollback.sh <product>` (deploy also auto-rolls back on failed health) |
| Backups | nightly 01:30 pgBackRest (full Sun / diff) → `s3://collective-<env>-backups/pgbackrest/<env>`; EBS snapshot 02:00 (DLM) |
| Verify backups | `docker exec platform-postgres-1 pgbackrest --stanza=collective info` |
| **Restore drill (monthly)** | on UAT: `sudo /opt/collective/platform/bin/restore-drill.sh prod` → report in `s3://…-backups/drills/`: per-database sanity, each product's `hooks/drill-smoke.sh` (getproperty: migrations complete + `node dist/src/drill-smoke.js` in the deployed api image), `rto_seconds` against the 30-min target, `RESULT: OK\|FAIL` (exit 1 on FAIL). The restored instance sits on an `--internal` network (no Valkey/EMQX/S3/internet) |
| Backups off-region | prod: DLM copies each daily snapshot to `ap-northeast-1` (encrypted, 7 days) — PDPA s.28 note in PLAN.md §0 |
| PITR | `restore-drill.sh prod --pitr "2026-11-01 02:00:00+07"` to inspect; real restore = stop products, same `pgbackrest restore` into `/data/postgres` |
| Wake UAT off-hours | `platform/bin/wake.sh uat` (stops again at 20:00) |
| Change hostnames | edit `platform/caddy/sites.<env>.yml` → PR → `platform-deploy.yml` |
| Resize box | change `instance_type` in `envs/<env>/terraform.tfvars` → PR (stop/start, ~3 min downtime) |
| Grow /data | bump `data_volume_size_gb` → apply → on box `sudo xfs_growfs /data` |
| Rotate a secret | update Secrets Manager → `secrets-refresh.timer` renders hourly → next deploy picks it up (or `deploy-product.sh <p> <same-tag>`) |
| Move a database to a DB box | trigger (PLAN.md §0): a product database > 100 GB or `/data` > 70 %. Second EC2 box with the same `timescaledb-ha` image (compose + SSM), `pg_dump`/restore or a streaming replica, then change only that product's `DATABASE_URL`. EC2 only — never RDS |
| Memory / mode knobs | `platform/env/<env>.env` (non-secret, PR-reviewed): `POSTGRES_MEMORY_LIMIT`, `CLAMAV_MEMORY_LIMIT`, `GETPROPERTY_WORKER_MEMORY`, `GETPROPERTY_PDF_RENDERER_MODE` → `platform-deploy.yml`, then redeploy the product |
| Device CA / broker certificate | put the new JSON into `collective/<env>/platform/device-ca` → hourly refresh (or `bin/fetch-secrets.sh platform`) restarts EMQX's ssl listener and reloads Caddy; redeploy getproperty-api so it signs with the new issuing key. Broker certificate: 397 days |

## 6. Conventions

- `terraform fmt -recursive` before commit; CI enforces it.
- Never `terraform apply` prod from a laptop once CI works — use the PR → approval path.
- `prevent_destroy` guards the data volume, backup bucket and asset buckets. Removing it is a reviewed PR.
- No secrets in this repo, in tfvars, or in GitHub secrets: Secrets Manager is the only store; CI uses OIDC roles.

## 7. Not verified in this repository (UNVERIFIED)

There are no `terraform`, `docker`, `caddy` or `emqx` binaries where this repo was last edited; these were written
against the vendors' documentation and must be proven on the first UAT apply / deploy:

- `terraform fmt -check` / `validate` of every root — in particular `cross_region_copy_rule` (`target`, `cmk_arn`)
  on `aws_dlm_lifecycle_policy` with provider 6.x, and the DLM copy from the opt-in region `ap-southeast-7`.
- EMQX 5.8: HOCON values in env vars for the per-listener `authentication` chains (8883, 8083) and for
  `authorization.sources`; the HTTP placeholders `${cert_common_name}`, `${cert_subject}`, `${qos}`, `${retain}`;
  `peer_cert_as_username = cn` before HTTP authn; the built-in-database bootstrap file.
- Caddy 2.10: `tls <cert> <key>` for `MQTT_HOST` (device-CA certificate), WebSocket proxying with
  `stream_close_delay`, `client_auth` + `trust_pool file` on `DEVICE_HOST`, the `/internal/*` 404 snippet.
- ClamAV `clamav/clamav-debian:1.4`: the replaced `clamd.conf` with the image's entrypoint, `clamdcheck.sh`, the
  `/data/clamav` ownership, and the steady RSS (≈ 1.1 GB) inside the 1,152 MB limit.
- `restore-drill.sh` end to end (the `--internal` network, the getproperty smoke, `node dist/src/drill-smoke.js`, which
  getproperty-api provides).
- Compose interpolation of `${GETPROPERTY_WORKER_MEMORY:-1536M}` in `deploy.resources.limits.memory`.
