# Collective Infrastructure — Rollout Plan

> Repo นี้คือ **source of truth** ของ cloud infrastructure ทั้งหมดของ Collective Group (Thailand):
> Terraform สำหรับ AWS, docker compose ของ shared platform บน EC2, และ reusable GitHub Actions
> ที่ product repos (getpack, getproperty, getpop) เรียกใช้ ทุกการแก้ไข cloud ต้องผ่าน PR ที่ repo นี้ — ไม่แก้ผ่าน console

## 0. Decisions (locked 2026-10-20, amended 2026-10-21)

> 2026-10-21: the founder's locked infrastructure decisions (`docs/BLUEPRINT-ALIGNMENT-PROMPT.md` §A — EC2 only, one
> secret per product per env, memory budget, one Chromium per box) are the frame for every row below; do not re-open them.

| Area | Decision |
|---|---|
| Region | `ap-southeast-7` (AWS Thailand) — opt-in region, ต้อง enable ใน account ก่อน |
| Compute | **EC2 only, forever** (Config C): 1 Graviton EC2 ต่อ env รัน docker compose ทุก product; ไม่มี ALB/Fargate/ECS/EKS/RDS/ElastiCache/NAT/Lambda-for-app-logic. Scale = resize box → แยก worker box / DB box / GPU box (compose + SSM แบบเดียวกัน) |
| Production | `t4g.xlarge` (4 vCPU / 16 GB), 24×7, EBS gp3 root 30 GB + data 120 GB |
| UAT | `t4g.large` (2 vCPU / 8 GB), EventBridge Scheduler start 08:00 / stop 20:00 Mon–Fri (Asia/Bangkok), EBS data 60 GB |
| Database | 1 PostgreSQL 18 instance (`timescale/timescaledb-ha:pg18` — มี TimescaleDB + pgvector + pgBackRest ในตัว), 1 database + 1 role ต่อ product, data บน EBS volume แยก |
| Queue / cache | 1 Valkey instance, logical DB แยกต่อ product |
| MQTT | EMQX 5.8 = **shared platform broker**. **8883 public, mutual TLS** ด้วย **device CA** (`collective/<env>/platform/device-ca`; server certificate ออกจาก CA เดียวกัน — **ไม่ใช่ Let's Encrypt** เพราะ gateway trust เฉพาะ `caChainPem` ที่ได้ตอน bootstrap), CN `gw-<gatewayId>` = username; **1883 internal only** (docker network, password users); **8083 ws หลัง Caddy เท่านั้น** (`wss://<MQTT_HOST>/mqtt`, cert จาก device CA, gateway ที่ตึกบล็อก 8883 ใช้ device JWT อย่างเดียว — getproperty O-012). Authn/authz = HTTP → getproperty-api `/internal/emqx/{authn,authz}` (docker network only; Caddy ตอบ 404 ให้ `/internal/*` ทุก host); namespace `gp/v1/#` เป็นของ getproperty |
| Ingress | Caddy (auto-TLS) route ตาม hostname → container ของแต่ละ product |
| Backup | pgBackRest full (Sun) + diff (daily) + WAL archive (`archive_timeout` 300 s → **RPO ≤ 5 min**) → S3 (35-day retention) + DLM EBS snapshot daily (prod 7 วัน) **+ cross-region copy → `ap-northeast-1` (Tokyo), encrypted, 7 วัน (prod)** + restore drill รายเดือน พร้อม smoke test ของแต่ละ product และจับเวลาเทียบ **RTO 30 min**. ไม่มี managed failover (HA = streaming replica บน DB box ถ้าจำเป็น) |
| PDPA (cross-border) | snapshot copy ใน Tokyo ทำให้ข้อมูลส่วนบุคคลออกนอกประเทศไทย (ม.28): เข้ารหัส (EBS/KMS), AWS เป็นผู้ประมวลผลตาม DPA, ญี่ปุ่นมีกฎหมายคุ้มครองข้อมูลครอบคลุม (APPI); ระบุใน ROPA/DPA ของแต่ละ product (getproperty O-016 — ถ้อยคำ DPA ให้ legal ยืนยัน). Erasure ไปถึงสำเนาภายใน 7 วัน (snapshot) / 35 วัน (pgBackRest); หลัง restore ใด ๆ ต้อง re-apply DSR ที่ทำหลังจุด restore |
| Isolation | S3 bucket / SES identity / ECR repo แยกต่อ product; compose project แยก (`platform` + 1 ต่อ product); 1 database + 1 role ต่อ product, ไม่มี cross-database query; cross-product = outbox → HTTP webhook (box เดียวกัน) หรือ SNS/SQS |
| Secrets | **1 secret ต่อ product ต่อ env**: `collective/<env>/<product>/app` (flat JSON). Key ของ component เดียวใช้ prefix `<COMPONENT>__` (getproperty: `WEB__…`, `LIFF__…`) ซึ่ง `fetch-secrets.sh` แยกเป็น env file ของ component นั้น (ตัด prefix) — front end ไม่เคยได้ secret ของ API. Platform secrets: `collective/<env>/platform/{postgres,valkey,emqx,grafana,caddy,deploy-key,device-ca}` |
| Upload virus scan | ClamAV **1 ตัวต่อ box** ใน compose project `platform` (`platform-clamav-1:3310`, INSTREAM, docker network only) — product ใช้ `CLAMAV_HOST=platform-clamav-1` |
| PDF | Chromium **ตัวเดียวต่อ box** (getpack worker) เป็น consumer ของ BullMQ queue กลาง **`pdf-render`** (HTML in → S3 key out; owner = getpack worker; contract: getproperty-api `docs/pdf-render-queue.md`, D-236). product อื่นใช้ queue นี้ หรือมี ADR + budget 1.5 GB สำหรับ Chromium ของตัวเอง (getproperty ชั่วคราวจนกว่า consumer จะ deploy: O-015, ADR-0012) |
| Access | ไม่มี SSH port — ใช้ SSM Session Manager / Run Command เท่านั้น |
| CI/CD | GitHub Actions + OIDC (ไม่มี long-lived keys) → ECR (arm64) → SSM Run Command `platform/bin/deploy-product.sh <product> <tag> [--component <name>]` (pull → migrate service ของ product → up → healthcheck → auto-rollback); `main` → UAT; tag `v*.*.*` หรือ `promote.yml` → prod ผ่าน GitHub Environment approval. Product หลาย repo (getproperty api/web/liff) deploy และ promote **ทีละ component** (`component: api\|web\|liff\|all`) — box รัน sha เดียวกับที่ UAT รัน |
| Migrations | one-shot service `migrate` ใน product compose (image ของ api): getpack `npx prisma migrate deploy`; getproperty **`node dist/src/migrate.js`** (asset-core `core` ก่อน → `prisma/migrations` บันทึกใน `_prisma_migrations` แบบ Prisma → TimescaleDB step → reference seed; ไม่มี Prisma CLI ใน image — ADR ใน getproperty-api, T-3) |
| OTA releases | getproperty-edge artefacts ใน bucket ของ product ใต้ prefix `releases/` (`releases/edge/<version>/<file>`): instance role **อ่านได้อย่างเดียว** (explicit deny put/delete), อัปโหลดด้วย policy `collective-<env>-getproperty-release-publisher` ของ release engineer; gateway ดาวน์โหลดผ่าน API บน `DEVICE_HOST` เท่านั้น |
| Observability | Grafana Alloy บน box → Grafana Cloud Free (metrics/logs/traces); CloudWatch เฉพาะ host alarms + EC2 auto-recovery; Sentry สำหรับ app errors |
| Cost target | ≈ USD 211/mo on-demand ทั้ง 2 env (≈ 172 หลัง 1-yr EC2 Instance Savings Plan บน prod) |

**Memory budget — prod box 16 GB (hard limits in compose; locked 2026-10-21)**

| Project | Budget | Limits |
|---|---|---|
| `platform` | ≈ 6 GB (6,144 MB) | caddy 256M · postgres 3,328M · valkey 512M · emqx 512M · alloy 384M · clamav 1,152M |
| getpack | 3.2 GB | web 512M · api 640M · worker 2G (the box's one Chromium, `pdf-render` consumer) |
| getproperty | ≈ 1.8 GB (1,792 MB) | api 512M · worker 512M · ingest 192M · web 384M · liff 192M (migrate 512M one-shot). **Interim** (O-015, ADR-0012): worker 1.5 GB with its own Chromium until getpack's `pdf-render` consumer is deployed → 2,816 MB (`GETPROPERTY_WORKER_MEMORY`, `GETPROPERTY_PDF_RENDERER_MODE` in `platform/env/<env>.env`) |
| getpop | ≈ 1.5 GB | api 512M · worker 1G |

ส่วนที่เหลือ (≈ 3.5 GB) = OS + page cache. Knobs ที่ไม่ใช่ secret ต่อ env อยู่ใน `platform/env/<env>.env` (PR-reviewed).
**uat** (`t4g.large`, 8 GB) ใช้ limits เดียวกับ prod เพื่อพิสูจน์ใต้ load ยกเว้น PostgreSQL 2g — ผลรวม ceilings เกิน 8 GB ซึ่งยอมรับบน UAT
เพราะ limit เป็นเพดาน ไม่ใช่การจอง; ดู `container_memory_working_set_bytes` ใน Grafana. Product ที่ต้องการเกิน budget ต้องระบุ trigger ที่จะย้ายไป box ของตัวเอง

**Explicit triggers to revisit** (บันทึกไว้เพื่อไม่ต้องถกใหม่ — ทุกทางเป็น EC2):
- CPUCreditBalance alarm ดังบ่อย → `m7g.xlarge`
- memory ของ box ไม่พอหลังปรับ limits → resize box (`instance_type`) ก่อน แล้วค่อยแยก box
- Python AI workers (จาก ~Mar 2027) → **worker box** แยก (compose + SSM เดียวกัน; ต่อ PostgreSQL/Valkey ของ main box ผ่าน private subnet)
- **DB box** (PostgreSQL บน EC2 แยก, streaming replica ถ้าต้องการ HA) เมื่อ database ของ product ใด > 100 GB หรือ `/data` > 70 % (getproperty O-014: telemetry ≈ 142 GB ปีแรกที่ 10,000 devices) — ขยาย `/data` 120 → 250 GB ก่อนตาม getproperty ask A-2
- GPU box (self-hosted models) เฉพาะ batch และต้องมี ADR — ไม่ก่อนปี 2028
- Grafana Cloud Free เกิน 50 GB logs/เดือน → Pro หรือ LGTM บน `t4g.small` แยก

## 1. Repository layout

```
collective-infra/
├── PLAN.md                        ← ไฟล์นี้
├── README.md                      ← how-to / runbooks
├── Makefile                       ← make plan ENV=uat, make apply ENV=prod …
├── bootstrap/                     ← รันครั้งเดียวด้วย local credentials: state bucket, GitHub OIDC provider, terraform role
├── envs/
│   ├── global/                    ← ECR repos, AWS Budgets alarm (region-independent)
│   ├── uat/                       ← network + app-server + scheduler + products + deploy-role
│   └── prod/                      ← เหมือน uat แต่ไม่มี scheduler, instance ใหญ่กว่า
├── modules/
│   ├── network/                   ← VPC, public subnets, IGW, security group
│   ├── app-server/                ← EC2 + EIP + data EBS + IAM role + CW agent + alarms + auto-recovery + DLM + user-data
│   ├── scheduler/                 ← EventBridge Scheduler start/stop
│   ├── product/                   ← S3 bucket, Secrets Manager shell, SES identity (+DKIM), IAM policy ต่อ product
│   ├── ecr/                       ← ECR repo + lifecycle policy
│   └── deploy-role/               ← IAM role สำหรับ GitHub OIDC (ssm:SendCommand, ecr push, ec2 start)
├── platform/                      ← สิ่งที่รันบน EC2 (ถูก clone ลง /opt/collective/infra)
│   ├── docker-compose.yml         ← caddy, postgres, valkey, emqx, clamav, alloy
│   ├── env/<env>.env              ← non-secret compose knobs ต่อ env (memory limits, modes)
│   ├── Caddyfile, caddy/templates/<product>.caddy, caddy/sites.<env>.yml
│   ├── alloy/config.alloy
│   ├── clamav/clamd.conf, emqx/platform-acl.conf
│   ├── postgres/{init/, postgresql.conf, pg_hba.conf, pgbackrest.conf}
│   ├── products/<product>/docker-compose.yml   ← template ต่อ product
│   ├── products/<product>/hooks/  ← post-secrets.sh (หลัง render secrets), drill-smoke.sh (restore drill)
│   ├── systemd/                   ← pgbackrest timers, compose autostart
│   └── bin/                       ← bootstrap.sh, deploy-product.sh, fetch-secrets.sh, render-device-ca.sh, healthcheck.sh, rollback.sh, restore-drill.sh
└── .github/workflows/
    ├── terraform.yml              ← fmt/validate/plan on PR, apply on main (prod ต้อง approve)
    ├── platform-deploy.yml        ← platform/ เปลี่ยน → SSM pull + compose up
    ├── reusable-build-push.yml    ← product repos เรียก: build arm64 → ECR
    └── reusable-deploy.yml        ← product repos เรียก: SSM deploy + healthcheck + rollback
```

## 2. Phases

### Phase 0 — Prerequisites (manual, ~1 hr)
- [ ] AWS account ของ Collective Group (แยกจาก account ส่วนตัว/Abbon), enable region **Asia Pacific (Thailand)** ใน Account settings
- [ ] IAM Identity Center หรือ IAM user ชั่วคราวที่มี AdministratorAccess สำหรับ bootstrap (ลบหลัง Phase 1)
- [ ] GitHub org สร้างแล้ว; repos: `collective-infra`, `getpack-api`, `getpack-web`, `getproperty-api`, `getproperty-web`, `getproperty-liff`, `getpop-api` (ชื่อจริงใส่ใน `envs/*/terraform.tfvars`)
- [ ] Domain: `getpack.co` + domain ของ getproperty / getpop (Route 53 หรือ registrar อื่น — Terraform ออก DNS records ให้ทั้งสองแบบ)
- [ ] Grafana Cloud Free stack สร้างแล้ว → เก็บ URL/API key ใน Secrets Manager `collective/<env>/platform/grafana`
- [ ] **getpack-web ยังไม่มี Dockerfile** → เพิ่ม `output: 'standalone'` ใน `next.config.ts` และ Dockerfile (template อยู่ใน `platform/products/getpack/Dockerfile.web.example`)

### Phase 1 — Bootstrap (ครั้งเดียว)
```
cd bootstrap && terraform init && terraform apply
```
สร้าง: S3 state bucket (versioning + SSE + native lockfile), GitHub OIDC provider, IAM role `gha-terraform`
(trust เฉพาะ `repo:<org>/collective-infra:*`). Output → ใส่ใน `envs/*/backend.hcl` และ GitHub repo variables

### Phase 2 — Global
`envs/global`: ECR repos ทุก image + lifecycle policy, AWS Budgets alert ที่ USD 250/300

### Phase 3 — UAT
`envs/uat`: VPC → EC2 t4g.large + EIP + data volume → scheduler → products (S3/Secrets/SES) → deploy role
หลัง apply:
1. ใส่ค่า secrets จริงใน Secrets Manager (`collective/uat/<product>/app`, `collective/uat/platform/*` รวม `device-ca` และ `emqx.getproperty_auth_token`)
2. DNS: ชี้ `uat.getpack.co`, `uat-api.getpack.co` ฯลฯ → EIP; เพิ่ม SES DKIM records
3. user-data จะ bootstrap docker + clone repo นี้ + `platform/bin/bootstrap.sh uat` อัตโนมัติ — ตรวจผ่าน SSM Session: `journalctl -u cloud-final`
4. Deploy product ตัวแรก (getpack) ผ่าน `reusable-deploy.yml`
5. ยืนยัน Grafana Cloud ได้ metrics/logs, CloudWatch alarm → SNS email

### Phase 4 — Production
`envs/prod` เหมือน UAT แต่ `t4g.xlarge`, data 120 GB, ไม่มี scheduler, DLM 7 วัน + cross-region copy `ap-northeast-1` 7 วัน, `deletion_protection`/`prevent_destroy` บน data volume และ buckets
- Restore drill ครั้งแรก **ก่อน** รับ order จริง: `platform/bin/restore-drill.sh` บน UAT จาก prod backup
- หลัง traffic นิ่ง 2–3 เดือน → ซื้อ 1-yr EC2 Instance Savings Plan (t4g, ap-southeast-7)

### Phase 5 — Product CI/CD wiring
แต่ละ product repo เพิ่ม `.github/workflows/deploy.yml` (ตัวอย่างใน README §4) ที่เรียก reusable workflows จาก repo นี้:
- push `main` → build → push `:sha-<short>` + `:uat` → deploy UAT
- tag `v*.*.*` (release.yml ที่มีอยู่แล้ว) → re-tag `:prod` → deploy prod (ต้อง approve ใน GitHub Environment `production`)

### Phase 6 — Go-live checklist
- [ ] pgBackRest: `pgbackrest info` แสดง full + WAL ต่อเนื่อง; restore drill ผ่าน (`RESULT: OK`, smoke ของทุก product OK, `rto_seconds` ≤ 1800)
- [ ] DLM: snapshot copy ปรากฏใน `ap-northeast-1` (prod)
- [ ] Alarms ทดสอบจริง (stop CW agent → alarm → email)
- [ ] EC2 auto-recovery ทดสอบด้วย `aws ec2 send-diagnostic-interrupt`? (ไม่ — ใช้ StatusCheck simulate ไม่ได้; ยอมรับจาก AWS docs)
- [ ] Caddy certs ครบทุก hostname (`curl -vI`)
- [ ] Secrets rotation runbook; ไม่มี secret ใน repo/GitHub
- [ ] Cost Explorer หลัง 7 วัน ≤ ฿300/วัน รวม 2 env

## 3. Non-goals (ตอนนี้)
Multi-AZ, auto-scaling, blue/green, WAF, private subnets/NAT, Kubernetes, self-hosted Grafana, IaC สำหรับ Grafana Cloud/Sentry (ทำด้วยมือ, 1 ครั้ง)
