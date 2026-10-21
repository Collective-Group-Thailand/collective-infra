# collective-infra — progress and assumptions

Newest first. Decisions that belong to a product are recorded in that product's repo (getproperty: getproperty-api
`docs/decisions.md`); this file records what was done here, the assumptions taken, and what this repo needs from
product repos.

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
