# Collective Infrastructure — Rollout Plan

> Repo นี้คือ **source of truth** ของ cloud infrastructure ทั้งหมดของ Collective Group (Thailand):
> Terraform สำหรับ AWS, docker compose ของ shared platform บน EC2, และ reusable GitHub Actions
> ที่ product repos (getpack, getproperty, getpop) เรียกใช้ ทุกการแก้ไข cloud ต้องผ่าน PR ที่ repo นี้ — ไม่แก้ผ่าน console

## 0. Decisions (locked 2026-10-20)

| Area | Decision |
|---|---|
| Region | `ap-southeast-7` (AWS Thailand) — opt-in region, ต้อง enable ใน account ก่อน |
| Compute | **Config C**: 1 EC2 ต่อ env รัน docker compose ทุก product; ไม่มี ALB/Fargate/RDS/NAT/k8s |
| Production | `t4g.xlarge` (4 vCPU / 16 GB), 24×7, EBS gp3 root 30 GB + data 120 GB |
| UAT | `t4g.large` (2 vCPU / 8 GB), EventBridge Scheduler start 08:00 / stop 20:00 Mon–Fri (Asia/Bangkok), EBS data 60 GB |
| Database | 1 PostgreSQL 18 instance (`timescale/timescaledb-ha:pg18` — มี TimescaleDB + pgvector + pgBackRest ในตัว), 1 database + 1 role ต่อ product, data บน EBS volume แยก |
| Queue / cache | 1 Valkey instance, logical DB แยกต่อ product |
| MQTT | EMQX 5.8 (getproperty IoT edge), TLS 8883 ผ่าน Caddy-issued cert |
| Ingress | Caddy (auto-TLS) route ตาม hostname → container ของแต่ละ product |
| Backup | pgBackRest full daily + WAL archive → S3 (35-day retention) + DLM EBS snapshot daily (7 days) + restore drill รายเดือน |
| Isolation | S3 bucket / Secrets / SES identity / ECR repo แยกต่อ product; compose project แยก (`platform` + 1 ต่อ product) |
| Access | ไม่มี SSH port — ใช้ SSM Session Manager / Run Command เท่านั้น |
| CI/CD | GitHub Actions + OIDC (ไม่มี long-lived keys) → ECR → SSM Run Command; promote image ด้วย tag `uat` → `prod`; prod ต้องผ่าน GitHub Environment approval |
| Observability | Grafana Alloy บน box → Grafana Cloud Free (metrics/logs/traces); CloudWatch เฉพาะ host alarms + EC2 auto-recovery; Sentry สำหรับ app errors |
| Cost target | ≈ USD 211/mo on-demand ทั้ง 2 env (≈ 172 หลัง 1-yr EC2 Instance Savings Plan บน prod) |

**Explicit triggers to revisit** (บันทึกไว้เพื่อไม่ต้องถกใหม่):
- CPUCreditBalance alarm ดังบ่อย → `m7g.xlarge`
- product ใดมี paying customers สม่ำเสมอ → ย้าย DB ของ product นั้นไป RDS Single-AZ
- ต้องการ zero-downtime deploy หรือ > 1 box → ALB + ECS/Fargate (image เดิมใช้ต่อได้) ค่อยพิจารณา ArgoCD ตอนขึ้น EKS
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
│   ├── docker-compose.yml         ← caddy, postgres, valkey, emqx, alloy
│   ├── Caddyfile
│   ├── alloy/config.alloy
│   ├── postgres/{init.sh, postgresql.conf.d, pgbackrest.conf}
│   ├── products/<product>/docker-compose.yml   ← template ต่อ product
│   ├── systemd/                   ← pgbackrest timers, compose autostart
│   └── bin/                       ← bootstrap.sh, deploy-product.sh, fetch-secrets.sh, healthcheck.sh, rollback.sh, restore-drill.sh
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
- [ ] GitHub org สร้างแล้ว; repos: `collective-infra`, `getpack-api`, `getpack-web`, `getproperty-api`, `getproperty-web`, `getpop-api` (ชื่อจริงใส่ใน `envs/*/terraform.tfvars`)
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
1. ใส่ค่า secrets จริงใน Secrets Manager (`collective/uat/<product>/app`, `collective/uat/platform/*`)
2. DNS: ชี้ `uat.getpack.co`, `uat-api.getpack.co` ฯลฯ → EIP; เพิ่ม SES DKIM records
3. user-data จะ bootstrap docker + clone repo นี้ + `platform/bin/bootstrap.sh uat` อัตโนมัติ — ตรวจผ่าน SSM Session: `journalctl -u cloud-final`
4. Deploy product ตัวแรก (getpack) ผ่าน `reusable-deploy.yml`
5. ยืนยัน Grafana Cloud ได้ metrics/logs, CloudWatch alarm → SNS email

### Phase 4 — Production
`envs/prod` เหมือน UAT แต่ `t4g.xlarge`, data 120 GB, ไม่มี scheduler, DLM 7 วัน, `deletion_protection`/`prevent_destroy` บน data volume และ buckets
- Restore drill ครั้งแรก **ก่อน** รับ order จริง: `platform/bin/restore-drill.sh` บน UAT จาก prod backup
- หลัง traffic นิ่ง 2–3 เดือน → ซื้อ 1-yr EC2 Instance Savings Plan (t4g, ap-southeast-7)

### Phase 5 — Product CI/CD wiring
แต่ละ product repo เพิ่ม `.github/workflows/deploy.yml` (ตัวอย่างใน README §4) ที่เรียก reusable workflows จาก repo นี้:
- push `main` → build → push `:sha-<short>` + `:uat` → deploy UAT
- tag `v*.*.*` (release.yml ที่มีอยู่แล้ว) → re-tag `:prod` → deploy prod (ต้อง approve ใน GitHub Environment `production`)

### Phase 6 — Go-live checklist
- [ ] pgBackRest: `pgbackrest info` แสดง full + WAL ต่อเนื่อง; restore drill ผ่าน
- [ ] Alarms ทดสอบจริง (stop CW agent → alarm → email)
- [ ] EC2 auto-recovery ทดสอบด้วย `aws ec2 send-diagnostic-interrupt`? (ไม่ — ใช้ StatusCheck simulate ไม่ได้; ยอมรับจาก AWS docs)
- [ ] Caddy certs ครบทุก hostname (`curl -vI`)
- [ ] Secrets rotation runbook; ไม่มี secret ใน repo/GitHub
- [ ] Cost Explorer หลัง 7 วัน ≤ ฿300/วัน รวม 2 env

## 3. Non-goals (ตอนนี้)
Multi-AZ, auto-scaling, blue/green, WAF, private subnets/NAT, Kubernetes, self-hosted Grafana, IaC สำหรับ Grafana Cloud/Sentry (ทำด้วยมือ, 1 ครั้ง)
