# collective-infra — progress and assumptions

Newest first. Decisions that belong to a product are recorded in that product's repo (getproperty: getproperty-api
`docs/decisions.md`); this file records what was done here, the assumptions taken, and what this repo needs from
product repos.

## 2026-10-24 — getproperty public site (MARKETING_HOST)

`getproperty.app` (UAT `uat.getproperty.app`) is the platform's public site, not the owner console (which stays on
`app.` / `uat-app.`). It is served by getproperty-web with `MARKETING_HOST` set: the marketing pages (`/`, `/pricing`,
`/legal/*`) answer there and every other path is a 308 to `OWNER_HOST`.

| Area | Change |
|---|---|
| Hosts | `sites.<env>.yml` getproperty `MARKETING_HOST` (uat `uat.getproperty.app`, prod `getproperty.app`); prod also `MARKETING_WWW_HOST: www.getproperty.app` |
| Caddy | `getproperty.caddy`: `MARKETING_HOST` joins the getproperty-web block; new `getproperty-www.caddy` (308 www → apex), rendered only where `MARKETING_WWW_HOST` is set |
| render-sites | New template marker `# requires-var: KEY` — the template is skipped (not an error) in an env whose sites yml lacks `KEY` |
| Secret | `init-secrets.sh` writes `WEB__MARKETING_HOST`; an existing secret needs it added by hand (`aws secretsmanager put-secret-value`) |
| Healthcheck | `MARKETING_HOST` maps to web (default), `/health` there answers 308 — accepted |
| DNS | Cloudflare A `uat` (and prod `@`, `www`) → the box EIP, DNS only |

## 2026-10-22 — aligned with getproperty-api 74bdcdc (D-239–D-248, ADR-0012–0015, RUNBOOK §§12–15)

| Item | Change |
|---|---|
| PDF queue (D-242) | Compose maps `GETPROPERTY_PDF_RENDERER_MODE` → `PDF_RENDERER_MODE` (confirmed) and sets `PDF_RENDER_QUEUE_PREFIX=collective`; Valkey `--databases 16`, **DB 15 = shared platform queues** (`PLATFORM_QUEUES_VALKEY_DB`); getproperty's `post-secrets.sh` writes `PDF_RENDER_REDIS_URL` = `REDIS_URL` with `/15` (a value in the secret wins, warned when not DB 15); getpack's worker comment names the same URL/prefix |
| S3 (pdf-render §6.4) | `products.getpack.pdf_render_producers = ["getproperty"]` → statement `PdfRenderProducerObjects` (Get/Put on `collective-<env>-getproperty-assets/tmp/pdf-render/*` only); `products.getproperty.tmp_expiration_days = 1` (current + noncurrent versions of `tmp/`) |
| EMQX (D-244) | Authn/authz bodies checked against `EmqxAuthnRequest` / `EmqxAuthzRequest` — all field names match, no change; api container `EMQX_HTTP_ALLOWED_CIDRS=172.30.0.0/16,127.0.0.0/8` (the `collective` network + loopback); `EMQX_SERVICE_USERNAMES` documented (optional, default `MQTT_USERNAME`) |
| `gp_mqtt` (0037) | New optional `hooks/post-migrate.sh` step in `deploy-product.sh`; getproperty's hook drops `gp_mqtt` once `20261022000037_0037_emqx_http_auth` is applied (idempotent, warn-only) |
| Integration events (D-247) | `INTEGRATION_<GETBUILD\|GETPACK>_{TRANSPORT,WEBHOOK_URL,SIGNING_KEYS,VERIFY_KEYS}` documented (README §3, compose header) with docker-network URLs; Caddy answers 404 for `/webhooks/integration/*` on every getproperty host |
| Provider credentials (D-240) | The three `*_SECRETS_PREFIX` lines removed from compose; README §3 gives the order: `credentials-import` with the prefixes passed by `-e`, check, then delete the sub-path secrets |
| Drill (D-248) | `dist/src/drill-smoke.js` ships in the image (getproperty-api 6b02d84): the SKIPPED fallback is gone; an image without it fails the drill |

**Assumptions** (founder pre-approved recommendations; most conservative option)

- **Valkey DB 15** for shared queues — not DB 0 as the example in getproperty-api `docs/pdf-render-queue.md` §2 shows:
  DB 0 is where a URL without a DB number lands, so a misconfigured product could write into the shared queue DB;
  15 is the highest DB of a 16-DB Valkey and nobody uses it by accident. getproperty keeps DB 2.
- `PDF_RENDER_REDIS_URL` is derived by the hook rather than kept as a separate secret key, so producer and consumer
  cannot drift onto different DBs and no second copy of the Valkey password is needed (getpack must set the same
  `/15` URL in its own secret until it has an equivalent hook).
- The cross-product S3 grant is attached to getpack's product policy. On one box the instance role is shared (it also
  carries getproperty's full-bucket policy), so today the grant is the declared contract; it becomes the enforced
  boundary once getpack's worker runs under its own role (worker box).
- **`gp_mqtt` stays in `postgres/init/20-getproperty.sh`** (contrary to the literal task "drop it from the init script
  for fresh boxes"): migration 0010 (immutable) executes `CREATE ROLE gp_mqtt` when it is missing, and the product
  login is NOCREATEROLE, so a fresh box without the role would fail its first migrate. The role is instead dropped
  after migrate by the post-migrate hook on fresh and existing boxes alike — the end state (no `gp_mqtt`) is the same.
- `EMQX_HTTP_ALLOWED_CIDRS` set to the `collective` network + loopback (narrower than the image default, which
  includes the VPC's 10.0.0.0/8).
- The drill treats a missing `drill-smoke.js` as a failure: every api image this branch can deploy is newer than
  6b02d84 (the branch needs the PDF queue env and the EMQX HTTP endpoints of that generation).

**Needs from getproperty-api / getpack** (recorded here; product docs are theirs to change)

1. getproperty-api `docs/pdf-render-queue.md` §2 / `docs/deployment.md` §2–3: name **Valkey DB 15** (`redis://:<pw>@valkey:6379/15`)
   instead of the `/0` example, and note that collective-infra's hook sets `PDF_RENDER_REDIS_URL` (not the secret).
2. getproperty-api `docs/deployment.md` §3 "Database roles": `gp_mqtt` is dropped by collective-infra's post-migrate
   hook after 0037; the init script keeps creating it for 0010 on fresh boxes.
3. getpack worker (pdf-render consumer, not implemented): `PDF_RENDER_REDIS_URL` with `/15`, prefix `collective`.

## 2026-10-22 — getproperty gap tasks on `getproperty/r1-platform` (blueprint "Infrastructure & operations")

Rebased onto the founder's `main` (b129586, locked decisions 2026-10-21) and implemented T-2, T-4, T-6, T-7, T-10,
T-11, T-15, T-17 and getproperty-api D-233…D-238 / O-012…O-016 (resolved by the founder as recommended).

| Task | Change |
|---|---|
| T-2 | Shared ClamAV in the `platform` project (`platform-clamav-1:3310`, 1,152 MB); getproperty's container removed |
| T-4 | One secret `collective/<env>/<product>/app`; `<COMPONENT>__` keys split by `fetch-secrets.sh`; `extra_secrets` removed from Terraform |
| T-6 | Platform secret `collective/<env>/platform/device-ca` → EMQX (8883 + WSS), Caddy device host, getproperty-api env |
| T-7 / O-012 | EMQX HTTP authn/authz → getproperty-api `/internal/emqx/{authn,authz}`; WSS fallback `wss://<MQTT_HOST>/mqtt` (JWT-only); PostgreSQL ACL source and `getproperty_mqtt` login removed; `/internal/*` 404 on every public host |
| T-10 | getproperty ingest health on :3001 |
| T-11 / O-015 | getproperty limits 1,792 MB; worker 1.5 GB interim via `GETPROPERTY_WORKER_MEMORY` while it runs Chromium |
| T-15 | `restore-drill.sh` product smoke hooks, isolated network, RTO measurement, real FAIL result |
| T-17 | PLAN.md / README.md aligned (EMQX device CA, migrate per product, budget, pdf-render, per-component promote, OTA prefix, EC2-only scale path) |
| O-013 | Provider-credential sub-paths kept, marked transitional until getproperty-api moves them into PostgreSQL |
| O-014 | DB-box trigger in PLAN.md: a product database > 100 GB or `/data` > 70 % |
| O-016 | DLM cross-region copy, prod → `ap-northeast-1`, encrypted, 7 days; PDPA s.28 note in PLAN.md |

**Assumptions** (founder pre-approved recommendations; most conservative option where the docs gave none)

- Platform ≈ 6 GB is met exactly (6,144 MB) by lowering PostgreSQL's limit from 4 GB to 3,328 MB to make room for
  ClamAV (1,152 MB, `ConcurrentDatabaseReload no`); `shared_buffers` stays 1 GB.
- O-016 named no region: `ap-northeast-1` (Tokyo) — not Singapore (locked decision 1), and the nearby destination with
  the strongest data-protection law for the PDPA s.28 basis. The DPA wording still needs legal sign-off.
- `gp_mqtt` is kept as a NOLOGIN role without members (contrary to the literal task) because getproperty-api's
  migration 0010 grants to it and creates a policy for it, and the product login cannot create roles: removing it
  would break migrations on a fresh box.
- WSS fallback serves the device-CA broker certificate on `MQTT_HOST` (not Let's Encrypt), so gateways verify 8883
  and WSS with the same `caChainPem`.
- HTTP hook secret: header `x-emqx-auth-token`, platform secret `platform/emqx.getproperty_auth_token`, API env
  `EMQX_AUTH_TOKEN`.
- The interim worker default in compose is 1536M (deploys work before the pdf-render consumer exists); the env files
  set it explicitly so the switch to `queue` / 512M is a reviewed one-line change.

**Needs from getproperty-api** (its session implements these; names here are what the platform sends/expects)

1. `POST /internal/emqx/authn` and `/internal/emqx/authz` require header `x-emqx-auth-token` = env `EMQX_AUTH_TOKEN`
   (refuse when empty). Authn body: `transport` (`mtls`|`ws`), `clientid`, `username`, `password`, `cert_common_name`,
   `cert_subject`, `peerhost`; on `ws` the certificate fields are empty (JWT-only, O-012). Authz body: `username`,
   `clientid`, `topic`, `action`, `qos`, `retain`, `peerhost`. Answers `{"result":"allow|deny|ignore"}`.
2. Device CA env: `DEVICE_CA_CERT`, `DEVICE_CA_KEY`, `DEVICE_CA_CHAIN` (base64 PEM) — `DEVICE_CA_CHAIN` is new (the
   gateways' `caChainPem` when the issuing CA is an intermediate).
3. `pnpm device:broker-cert` output for `collective/<env>/platform/device-ca`: keys `ca_chain_pem`, `issuing_cert_pem`,
   `issuing_key_pem`, `broker_cert_pem` (leaf + issuing), `broker_key_pem`.
4. `node dist/src/drill-smoke.js` in the api image (contract in `platform/products/getproperty/hooks/drill-smoke.sh`).
5. A migration that drops policy `mqtt_acl_rls_broker` and the grants to `gp_mqtt`; then the platform removes the
   role from `postgres/init/20-getproperty.sh`.
6. The pdf-render queue contract document referenced as `docs/pdf-render-queue.md` (rename here if it lands elsewhere).
7. O-013: provider credentials in PostgreSQL; then the three `*_SECRETS_PREFIX` lines leave the compose file.
