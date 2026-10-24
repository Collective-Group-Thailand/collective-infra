# getpack — Runbook: setup + deploy Production

> เอกสารนี้สรุปจากการขึ้น **UAT** จริง (23–24 ต.ค. 2026): ทุกขั้นที่ใช้ได้ ทุกจุดที่พัง และวิธีแก้ที่ใส่ไว้ในโค้ดแล้ว
> ใช้เป็นลำดับงานตอนขึ้น **Production** — ทำตามหัวข้อ 0 → 12 ตามลำดับ
>
> Repo: `Collective-Group-Thailand/collective-infra` (โครงสร้างพื้นฐาน + สคริปต์บนเครื่อง) ·
> `getpack-api` · `getpack-web` · บน Mac: `~/Collective/collective-infra`, `~/Collective/getpack/getpack-{api,web}`

---

## สารบัญ

0. [ภาพรวมและสิ่งที่ต่างจาก UAT](#0-ภาพรวมและสิ่งที่ต่างจาก-uat)
1. [งานที่ต้องเสร็จก่อนเริ่ม (pre-flight)](#1-งานที่ต้องเสร็จก่อนเริ่ม-pre-flight)
2. [Terraform: สร้าง prod](#2-terraform-สร้าง-prod)
3. [GitHub: environment + สิทธิ์](#3-github-environment--สิทธิ์)
4. [Secrets](#4-secrets)
5. [DNS (Cloudflare)](#5-dns-cloudflare)
6. [Amazon SES (production access)](#6-amazon-ses-production-access) · [6.1 Payment gateways](#61-payment-gateways-scb--2c2p--slip2go)
7. [Platform บนเครื่อง (bootstrap)](#7-platform-บนเครื่อง-bootstrap)
8. [Observability (Grafana Cloud)](#8-observability-grafana-cloud)
9. [Deploy getpack-api](#9-deploy-getpack-api)
10. [Deploy getpack-web](#10-deploy-getpack-web)
11. [ข้อมูลตั้งต้นของ Production](#11-ข้อมูลตั้งต้นของ-production)
12. [ตรวจรับหลังขึ้นระบบ (go-live checklist)](#12-ตรวจรับหลังขึ้นระบบ-go-live-checklist)
13. [Day-2: งานประจำ](#13-day-2-งานประจำ)
14. [ปัญหาที่เคยเจอบน UAT และวิธีแก้](#14-ปัญหาที่เคยเจอบน-uat-และวิธีแก้)
15. [ค่าอ้างอิง](#15-ค่าอ้างอิง)

---

## 0. ภาพรวมและสิ่งที่ต่างจาก UAT

```
Cloudflare DNS (DNS only) ──► EIP ──► EC2 t4g.xlarge (ap-southeast-7, arm64, 16 GB)
                                        ├─ platform (docker compose):  caddy · postgres 18 (timescale-ha) · valkey 8
                                        │                              emqx 5.8 · clamav · alloy → Grafana Cloud
                                        └─ getpack (compose project):  web · api · worker · migrate (one-shot)
S3: collective-prod-getpack-assets · collective-prod-backups (pgBackRest)     SES: ap-southeast-1
GitHub Actions ──OIDC──► collective-prod-gha-deploy ──SSM Run Command──► deploy-product.sh
```

| เรื่อง | UAT | **Production** |
|---|---|---|
| เครื่อง | t4g.large, 60 GB, เปิด จ–ศ 08:00–20:00 | **t4g.xlarge 16 GB, 120 GB, เปิด 24×7** (`schedule.enabled = false`) |
| Hostnames | `uat` · `uat-api` · `admin-uat` · `partner-uat` · `platform-uat` | **`getpack.co` · `api` · `admin` · `partner` · `www` · `platform`** (`.getpack.co`) |
| GitHub environment | `uat` | **`production`** (และ `terraform-prod`) |
| api image | build จาก main | **promote** sha ที่ผ่าน UAT (`promote.yml`) — ไม่ build ใหม่ |
| web image | build จาก main + `NEXT_PUBLIC_ENV_BADGE=uat` | **build ใหม่ด้วย build args ของ prod** (ดู §1.1) |
| Seed | reference + **uat** (ข้อมูลทดสอบ) | **reference เท่านั้น** + ข้อมูลจริงผ่านหน้า admin |
| Style library | `uat-style-fixture.js` (ผ่าน gate ด้วยบัญชีทดสอบ) | **import + อนุมัติจริง** โดยคนจริง (ห้ามใช้ fixture) |
| รูปหน้า home | ชุด `interim-unverified` | **ห้ามใช้** — ต้องเป็นรูปที่มีลิขสิทธิ์ชัด |
| SES | sandbox | **ต้องขอ production access** |
| Third-party keys | ว่างได้ | **ต้องครบ** (LINE, ThaiBulkSMS, Firebase, VAPID, Sentry) |

---

## 1. งานที่ต้องเสร็จก่อนเริ่ม (pre-flight)

### 1.1 Pipeline สำหรับ web ของ production (มีแล้ว — ต้องตั้งค่า)

Next.js ฝัง `NEXT_PUBLIC_*` ลงไปตอน build → image web ของ UAT ใช้กับ prod ไม่ได้ (badge "uat", host ของ UAT)
`getpack-web/.github/workflows/deploy.yml` จึงมี job ของ prod แยก:

```
push tag vX.Y.Z ─► check-tag (tag = package.json version และ commit อยู่บน main)
               ─► build-prod (environment production, :prod) ─► deploy-prod (component web, migrate: false)
```
- hosts ของ prod (`getpack.co`, `admin.`, `partner.`) และ `NEXT_PUBLIC_ENV_BADGE=prod` อยู่ใน workflow
- ค่า public อื่นของแต่ละ env อยู่ใน **GitHub Environment variable `BUILD_ARGS`** (reusable build อ่านให้เอง) — ตั้งก่อน tag แรก:
  ```bash
  gh variable set BUILD_ARGS --repo Collective-Group-Thailand/getpack-web --env production --body "$(cat <<'EOF'
  NEXT_PUBLIC_SENTRY_DSN=<browser DSN>
  NEXT_PUBLIC_FIREBASE_API_KEY=<…>
  NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=<…>
  NEXT_PUBLIC_FIREBASE_PROJECT_ID=<…>
  NEXT_PUBLIC_FIREBASE_APP_ID=<…>
  NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=<…>
  NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET=<…>
  NEXT_PUBLIC_LIFF_ID=<…>
  NEXT_PUBLIC_GTM_ID=<…>
  NEXT_PUBLIC_VAPID_PUBLIC_KEY=<…>
  EOF
  )"
  ```
  ค่าพวกนี้เป็น public (อยู่ใน JS bundle อยู่แล้ว) — **ห้ามใส่ secret** ใน `BUILD_ARGS` · UAT ใช้ตัวแปรเดียวกันใน environment `uat` ได้
- ปล่อย web: bump `version` ใน `package.json` → merge main → `git tag vX.Y.Z && git push origin vX.Y.Z`

### 1.2 ตัดสินใจเรื่อง approval ของ production
GitHub plan **Free** ตั้ง *Required reviewers* ให้ environment ของ private repo **ไม่ได้** (HTTP 422) แปลว่าใครมีสิทธิ์ write
ใน `collective-infra` / product repos ก็ deploy prod ได้ เลือกหนึ่งทาง:
- **อัปเกรด org เป็น GitHub Team** แล้วตั้ง reviewer ให้ `production` และ `terraform-prod` (แนะนำเมื่อมีคนอื่นช่วยดูแล)
- **อยู่ Free ต่อ** และจำกัดสิทธิ์ write ของ `collective-infra` ไว้ที่เจ้าของคนเดียว

### 1.3 ข้อมูลธุรกิจ / บัญชีภายนอกที่ต้องมี
- [ ] ข้อมูลบริษัทผู้ออกเอกสาร (`SEED_ENTITY_*`: ชื่อไทย/อังกฤษ, เลขผู้เสียภาษี, สาขา, ที่อยู่, โทร) — D-092
- [ ] LINE Login + Messaging channel (production), ThaiBulkSMS (sender ที่อนุมัติแล้ว), Firebase project (prod), VAPID key pair, Sentry project
- [ ] **Merchant account ของ Collective Group เอง**: SCB Open API (QR 30 Biller ID + QR CS), 2C2P PGW, Slip2Go (§6.1) — onboarding ใช้เวลาหลายสัปดาห์ เริ่มก่อน
- [ ] อีเมลผู้รับ alert จริง (`alert_emails` ใน tfvars — ตอนนี้ยังเป็น TODO)
- [ ] รูปหน้า home ที่มีลิขสิทธิ์/เครดิตชัด (ชุด UAT เป็น `interim-unverified` ซึ่ง build web prod จะปฏิเสธอยู่แล้ว)
- [ ] รูปสินค้า/แบบกล่องของ prod (ชุด UAT เป็นข้อมูลทดสอบ — D-426)
- [ ] โรงงานจริงรายแรก + ผลตรวจโรงงาน (site visit) จริง สำหรับยืนยัน capability (§11.3)

### 1.4 ตรวจ code ที่จะขึ้น
- [ ] api sha ที่จะ promote ผ่าน UAT แล้ว (CI เขียว, ทดสอบ UAT ผ่าน)
- [ ] `pnpm typecheck && pnpm lint && pnpm test` ผ่านทั้งสอง repo (บน UAT เคย deploy แบบข้ามเทส — prod ห้ามข้าม)
- [ ] เฝ้าดู memory ของ api บน UAT แล้วนิ่ง (§13 — เคย OOM ที่ ~320 MB)
- [ ] sha ของ api ที่จะ promote มีสคริปต์ `create-superadmin` แล้ว (§11.2)
- [ ] ตั้ง `BUILD_ARGS` ของ environment `production` ใน getpack-web (§1.1) และ tag `v1` ของ `collective-infra` ชี้ commit ล่าสุด

---

## 2. Terraform: สร้าง prod

ทำจาก Mac ด้วย `AWS_PROFILE=collective` (account `231438713843`; `make` มี guard `envs/account.txt` กันผิด account)

```bash
cd ~/Collective/collective-infra
# 1) ทบทวน envs/prod/terraform.tfvars: alert_emails, platform_hostname, instance_type, products.getpack.ses_domain = "getpack.co"
# 2) global (ECR, budget) — ปกติมีแล้วจาก UAT
AWS_PROFILE=collective make init ENV=global && AWS_PROFILE=collective make plan ENV=global && AWS_PROFILE=collective make apply ENV=global
# 3) prod
AWS_PROFILE=collective make init ENV=prod
AWS_PROFILE=collective make plan ENV=prod        # อ่าน plan ทุกบรรทัด
AWS_PROFILE=collective make apply ENV=prod
AWS_PROFILE=collective make output ENV=prod      # จด instance_id, public_ip, deploy_role_arn, ses_dns_records
```

ข้อควรรู้
- **ห้าม apply prod ผ่าน GitHub โดยไม่ตั้งใจ**: `terraform.yml` ตอน merge จะ apply แค่ `global` + `uat` เท่านั้น; prod ต้อง
  `workflow_dispatch root=prod` (environment `terraform-prod`) หรือ apply จาก Mac
- ถ้า environment `terraform-prod` **ไม่มี** var `AWS_TERRAFORM_ROLE_ARN` = GitHub apply prod ไม่ได้เลย (ปลอดภัยที่สุดบน plan Free)
- OIDC: ใส่ `github_org_id = 346483067` ไว้แล้ว (GitHub ส่ง sub แบบ immutable `repo:Org@id/repo@id:…` — §14)
- SES อยู่ `ap-southeast-1` ผ่าน provider alias `aws.ses` (ap-southeast-7 ไม่มี SES)
- Instance มี `ignore_changes = [ami, user_data, associate_public_ip_address]` — แก้ user-data แล้วไม่ replace เครื่อง

---

## 3. GitHub: environment + สิทธิ์

```bash
ORG=Collective-Group-Thailand
ROLE=$(AWS_PROFILE=collective terraform -chdir=envs/prod output -raw deploy_role_arn)   # collective-prod-gha-deploy
IID=$(AWS_PROFILE=collective terraform -chdir=envs/prod output -raw instance_id)
for r in collective-infra getpack-api getpack-web; do
  gh api -X PUT repos/$ORG/$r/environments/production >/dev/null
  gh variable set AWS_DEPLOY_ROLE_ARN --repo $ORG/$r --env production --body "$ROLE"
  gh variable set INSTANCE_ID        --repo $ORG/$r --env production --body "$IID"
  gh variable set AWS_REGION         --repo $ORG/$r --env production --body ap-southeast-7
done
```
- ชื่อ environment ต้องเป็นตัวพิมพ์เล็ก **`production`** ตรงตัว (trust policy เทียบแบบ case-sensitive)
- Reusable workflow ข้าม repo: `collective-infra` ตั้ง Actions access = organization ไว้แล้ว
- Tag `v1` ของ `collective-infra` = API ของ reusable workflows — ถ้าแก้ workflow ต้องย้าย tag (`git tag -f v1 && git push -f origin v1`)

---

## 4. Secrets

ทุก secret อยู่ใน **Secrets Manager** `collective/prod/…` เท่านั้น — ไม่อยู่ใน repo / GitHub / ไฟล์บนเครื่อง (เครื่อง render ลง `/run/collective` ซึ่งเป็น tmpfs)

```bash
cd ~/Collective/collective-infra
bash platform/bin/init-secrets.sh prod          # ห้ามใช้ sudo; ไม่เขียนทับค่าที่มีอยู่
```
สคริปต์สร้าง: `platform/postgres`, `platform/valkey`, `platform/emqx`, `platform/caddy` (basic-auth bcrypt),
`platform/deploy-key` (ed25519 → `gh repo deploy-key add` ให้ `collective-infra`), `getpack/app`
และเก็บ plaintext ไว้ที่ `~/.collective-secrets/prod/` → **ย้ายเข้า password manager แล้วลบทิ้ง**

จากนั้นเติมค่าใน `collective/prod/getpack/app` (console หรือ `jq` merge):

| Key | Production |
|---|---|
| `PUBLIC_API_BASE_URL` | `https://api.getpack.co` (ห้ามมี `.invalid`) |
| `MERCHANT_FEED_LINK_TEMPLATE` | URL จริงของหน้าสินค้า (ห้ามมี `.invalid`) |
| `PUBLIC_WEB_URL` / `STOREFRONT_BASE_URL` | `https://getpack.co` (`STOREFRONT_BASE_URL` = หน้ากลับของ 2C2P — ขาดแล้วจะเป็น `www.getpack.invalid`) |
| `SES_FROM_ADDRESS` | เช่น `getpack <no-reply@getpack.co>` (domain ต้อง verify แล้ว) |
| `SES_REGION` | `ap-southeast-1` |
| `INTEGRATIONS_MODE` | `real` |
| `TRUST_PROXY` | `1` (หลัง Caddy) |
| `LINE_*`, `THAIBULKSMS_*`, `FIREBASE_PROJECT_ID`, `VAPID_*`, `SENTRY_DSN` | ค่าจริงของ prod |
| `SCB_*`, `TWOC2P_*`, `SLIP2GO_*` | ค่า production ของ merchant (§6.1) |

> `JWT_SIGNING_KEYS`, `OTP_HMAC_SECRET`, `FIELD_ENCRYPTION_KEY` (32 B base64), `LOOKUP_HMAC_SECRET` สคริปต์สร้างให้แล้ว
> — **ต้องไม่ใช้ค่าเดียวกับ UAT** และห้ามเปลี่ยน `FIELD_ENCRYPTION_KEY`/`LOOKUP_HMAC_SECRET` หลังมีข้อมูลจริง (ถอดรหัสข้อมูลเก่าไม่ได้)

ตัวอย่าง merge โดยไม่พิมพ์ค่าลง history:
```bash
read -rs -p 'THAIBULKSMS_API_SECRET: ' V; echo
CUR=$(AWS_PROFILE=collective aws secretsmanager get-secret-value --secret-id collective/prod/getpack/app --query SecretString --output text)
AWS_PROFILE=collective aws secretsmanager put-secret-value --secret-id collective/prod/getpack/app \
  --secret-string "$(jq -c --arg v "$V" '.THAIBULKSMS_API_SECRET=$v' <<<"$CUR")" >/dev/null && echo ok
unset V CUR
```

---

## 5. DNS (Cloudflare)

**ทุก record = DNS only (เมฆเทา)** — Caddy ขอ cert เอง, MQTT 8883 ผ่าน proxy ไม่ได้, DKIM ต้องตอบตรง

| Type | Name | Value |
|---|---|---|
| A | `@` (getpack.co) | `<prod public_ip>` |
| A | `www` | `<prod public_ip>` |
| A | `api` | `<prod public_ip>` |
| A | `admin` | `<prod public_ip>` |
| A | `partner` | `<prod public_ip>` |
| A | `platform` | `<prod public_ip>` |
| CNAME ×3 | `xxxx._domainkey` | `xxxx.dkim.amazonses.com` |
| MX | `mail` | `feedback-smtp.ap-southeast-1.amazonses.com` priority 10 |
| TXT | `mail` | `v=spf1 include:amazonses.com -all` |
| TXT | `_dmarc` | ตาม output (ปรับ `rua=` ให้เป็น mailbox ที่มีจริง) |

ดึง SES records:
```bash
AWS_PROFILE=collective terraform -chdir=envs/prod output -json ses_dns_records \
 | jq -r '.[][] | [.type, (.name | sub("\\.getpack\\.co$";"")), .value] | @tsv' | column -t -s $'\t'
```

> ⚠️ ถ้า `getpack.co` เดิมมีเว็บ/อีเมลอยู่แล้ว ตรวจ record เดิม (MX ของ mailbox หลัก, SPF ของ root) ก่อนแก้ —
> SES ใช้ MAIL FROM `mail.getpack.co` จึงไม่ชน MX ของ root

ตรวจ:
```bash
for h in @ www api admin partner platform; do n=$([ $h = @ ] && echo getpack.co || echo $h.getpack.co); printf '%-20s %s\n' $n "$(dig +short $n @1.1.1.1)"; done
```

---

## 6. Amazon SES (production access)

1. DNS ข้อ 5 ครบ → ตรวจ verify:
   ```bash
   AWS_PROFILE=collective aws sesv2 get-email-identity --region ap-southeast-1 --email-identity getpack.co \
     --query '{dkim:DkimAttributes.Status, mailfrom:MailFromAttributes.MailFromDomainStatus}'   # ทั้งคู่ SUCCESS
   ```
2. **ขอออกจาก sandbox** (ap-southeast-1): SES console → Account dashboard → *Request production access*
   (ระบุ use case: transactional — OTP/order/e-Tax, ประมาณจำนวน/วัน, วิธีจัดการ bounce/complaint) — ใช้เวลา ~1 วันทำการ
3. ระหว่างรอ ส่งได้เฉพาะอีเมลที่ verify แล้ว

### 6.1 Payment gateways (SCB · 2C2P · Slip2Go)

โค้ดมีครบแล้วใน getpack-api (B3.2, D-176; รายละเอียดใน `getpack-api/docs/integrations/payment-providers.md`) แต่ **ปิดด้วย feature flag**
จนกว่าจะมี merchant account ของ Collective Group เอง (D-005) — ระหว่างนั้นลูกค้าจ่ายด้วยการโอน + แนบสลิป และ Finance ตรวจเอง

| Provider | ใช้ทำอะไร | Flag | Keys (`collective/<env>/getpack/app`) |
|---|---|---|---|
| SCB Open API | PromptPay QR 30 (bill payment) + QR CS | `payments.scb` | `SCB_API_BASE_URL`, `SCB_API_KEY`, `SCB_API_SECRET`, `SCB_BILLER_ID` (15 หลัก), `SCB_REF3_PREFIX`, `SCB_MERCHANT_ID`, `SCB_TERMINAL_ID` |
| 2C2P PGW 4.x | บัตร, online banking, refund | `payments.twoc2p` | `TWOC2P_BASE_URL` (`https://pgw.2c2p.com`), `TWOC2P_API_VERSION`, `TWOC2P_MERCHANT_ID`, `TWOC2P_SECRET_KEY`, `TWOC2P_PAYMENT_ACTION_URL`, `TWOC2P_MERCHANT_PRIVATE_KEY` (PKCS#8 PEM), `TWOC2P_PUBLIC_KEY` (PEM) |
| Slip2Go | ตรวจสลิปอัตโนมัติ (ปิด = Finance ตรวจเอง) | `payments.slip_verify` | `SLIP2GO_API_URL`, `SLIP2GO_SECRET_KEY` |

> `payments.twoc2p_ipp` และ `payments.scb_direct_debit` เป็น R2 (adapter stub) — **ห้ามเปิดบน production** (D-296)

ขั้นตอน (ทำกับ UAT ด้วย sandbox ก่อน แล้วค่อย prod):
1. **Callback URL ที่ต้องลงทะเบียนกับ provider** (ผ่าน Caddy → getpack-api):
   - SCB (ต่อ Biller ID + Ref3 prefix และต่อ Merchant ID): `https://api.getpack.co/webhooks/scb/payment-confirmation`
   - 2C2P backend notification: `https://api.getpack.co/webhooks/2c2p/payment` · หน้ากลับ (browser) = `STOREFRONT_BASE_URL`
   - UAT: แทน `api.getpack.co` ด้วย `uat-api.getpack.co` — ยืนยัน path จริงจาก OpenAPI (`/docs`) ก่อนส่งให้ provider
2. **IP ขาออกของเครื่อง = EIP** (UAT `43.211.94.171`, prod ดู `terraform output public_ip`) — ถ้า provider ต้อง whitelist IP ผู้เรียก API ให้ใช้ค่านี้
   (EIP คงที่ แม้ stop/start เครื่อง) · ถ้า SCB ให้รายการ IP ต้นทางของ callback มา ค่อยพิจารณาจำกัดที่ Caddy
3. ใส่ keys ลง secret (ใช้วิธี `read -rs` + `jq` ตาม §4 — **PEM ทั้งก้อนใส่เป็น string เดียว**) → deploy api ซ้ำ (`deploy-product.sh getpack api <tag เดิม>`) เพื่อให้ secret ใหม่มีผล
4. Superadmin เปิด flag ที่ `/v1/admin/feature-flags` ทีละตัว หลังทดสอบจ่ายจริงผ่าน
5. ทดสอบ: QR 30 จ่ายจริง 1 บาท → callback → payment `confirmed` (adapter **inquiry ยืนยันทุก callback** เพราะ SCB callback ไม่มี signature);
   2C2P บัตรทดสอบ → backend notification (JWT HS256) → inquiry → `confirmed`; refund 2C2P → `RF`
6. ข้อที่ provider ต้องยืนยัน (ตามเอกสาร getpack-api): production base URL ของ SCB, รายการ IP ของ callback, API void/refund ของ QR 30
   (ตอนนี้ refund SCB = Finance โอนคืนเองแล้วบันทึก), payment channel ของ 2C2P ตามสัญญา

---

## 7. Platform บนเครื่อง (bootstrap)

user-data ของ EC2 ทำให้เองตอนสร้างเครื่อง: format `/data` (XFS label `cdata`), ติดตั้ง docker, clone `collective-infra`
ด้วย deploy key, รัน `platform/bin/bootstrap.sh` (systemd units, secrets, Caddy sites, compose up, pgBackRest stanza + full backup แรก)

> deploy key ต้องมีใน Secrets Manager **ก่อน** เครื่องบูต (ข้อ 4) — ถ้าเครื่องขึ้นก่อน ให้รัน bootstrap ซ้ำตามด้านล่าง

เข้าเครื่อง: `AWS_PROFILE=collective aws ssm start-session --region ap-southeast-7 --target <instance-id>` (ไม่มี SSH)

ตรวจ:
```bash
sudo docker ps --format 'table {{.Names}}\t{{.Status}}' | sort
# caddy / postgres / valkey / emqx / clamav = (healthy) ; alloy รันเมื่อมี grafana secret
cat /var/lib/collective/getpack.hosts.env                          # WEB/API/ADMIN/PARTNER_HOST ของ prod
sudo docker exec platform-postgres-1 pgbackrest --stanza=collective info   # status: ok + full backup
sudo docker exec platform-postgres-1 psql -U postgres -Atc '\l' | cut -d'|' -f1   # getpack, getpack_shadow, …
curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' https://platform.getpack.co/healthz   # 200 0
```
รัน bootstrap ซ้ำ (idempotent):
```bash
sudo bash -c 'cd /opt/collective/infra && git fetch -q origin && git reset -q --hard origin/main && bash platform/bin/bootstrap.sh'
```
หรือจาก GitHub: `collective-infra` → Actions → **Platform deploy** → environment `production`

ClamAV ครั้งแรกโหลด signature ~3–5 นาทีก่อนเป็น healthy (ระหว่างนั้นไฟล์ upload จะ `pending` แล้ว worker สแกนให้ทีหลัง)

---

## 8. Observability (Grafana Cloud)

แนะนำ **stack แยกสำหรับ prod** (หรือ stack เดียวแต่แยกด้วย label `env="prod"` — free tier 10k series พอสำหรับเริ่ม)

ค่าใน secret `collective/prod/platform/grafana`:

| key | ที่มา (portal → stack → Details) |
|---|---|
| `prometheus_url` / `prometheus_user` | Prometheus → Remote Write Endpoint / Username |
| `loki_url` / `loki_user` | Loki → URL **+ `/loki/api/v1/push`** / User (ลืม path = HTTP 405) |
| `tempo_url` / `tempo_user` | การ์ด **OpenTelemetry** → OTLP endpoint (`…/otlp`) / Instance ID (ไม่ใช่การ์ด Tempo) |
| `api_key` | Access Policies → scopes `metrics:write logs:write traces:write` → Add token (`glc_…`) |

```bash
read -s GK && echo
AWS_PROFILE=collective aws secretsmanager put-secret-value --secret-id collective/prod/platform/grafana --secret-string "$(jq -n \
  --arg pu '<prometheus url>' --arg pi '<user>' --arg lu '<loki url>/loki/api/v1/push' --arg li '<user>' \
  --arg tu '<otlp url>' --arg ti '<instance id>' --arg k "$GK" \
  '{prometheus_url:$pu, prometheus_user:$pi, loki_url:$lu, loki_user:$li, tempo_url:$tu, tempo_user:$ti, api_key:$k}')" >/dev/null && echo ok
unset GK
# บนเครื่อง
cd /opt/collective/platform && sudo bin/fetch-secrets.sh platform && sudo bash -c 'source bin/lib.sh && compose_platform up -d'
```
ตรวจใน Explore: Prometheus `count by (job) (up{env="prod"} == 1)` → `alloy caddy emqx integrations/unix integrations/postgres integrations/redis` (+cadvisor);
Loki `{env="prod"}`

ตั้ง alert ขั้นต่ำ: api restart/OOM, `up == 0`, disk `/data` > 80%, pgBackRest backup ไม่สำเร็จ > 26 ชม., CPU credit balance ต่ำ (t4g)

---

## 9. Deploy getpack-api

Production **ไม่ build ใหม่** — promote sha ที่ผ่าน UAT:

`collective-infra` → Actions → **Promote image uat → prod** → Run workflow
- product: `getpack` · component: `api` · image_tag: `sha-xxxxxxx` (ว่าง = ตัวที่ `:uat` ชี้อยู่) · migrate: ✅

ขั้นตอนบนเครื่อง (`deploy-product.sh getpack api <tag>`): fetch secrets → ECR login → pull → **`prisma migrate deploy`**
(service `migrate`, CLI ที่ `/opt/prisma-cli`) → `up api worker --wait` → health (container + edge `https://api.getpack.co/health`)
→ ถ้าไม่ผ่าน **rollback อัตโนมัติ** ไป tag ก่อนหน้า (deploy ครั้งแรกที่ล้ม = หยุด container และล้าง tag)

ตรวจ:
```bash
curl -s https://api.getpack.co/health | jq .status      # "ok" (database/redis/storage up)
sudo docker exec platform-postgres-1 psql -U postgres -d getpack -Atc \
  "select count(*) from _prisma_migrations where finished_at is not null"   # = จำนวนโฟลเดอร์ใน prisma/migrations (ไม่นับ migration_lock.toml)
sudo docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' | grep getpack   # api < 1 GB, worker < 2 GB
```

---

## 10. Deploy getpack-web

หลัง api ขึ้นแล้ว และ DNS + cert ของ `getpack.co / www / admin / partner` พร้อม (edge check ต้องผ่านทุก host ไม่งั้น rollback)

```bash
for h in getpack.co www.getpack.co admin.getpack.co partner.getpack.co; do
  printf '%-22s ' $h; curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' --max-time 10 https://$h/ 2>&1 | tail -1; done
# ต้องได้ตัวเลข (502 ก่อน deploy ก็ได้) + ssl_verify_result = 0 ; TLS error = cert ยังไม่ออก → caddy reload --force
```
Deploy: push tag `vX.Y.Z` ใน getpack-web (pipeline §1.1) — `deploy-product.sh getpack web <tag>` (migrate: false)

ตรวจ: `getpack.co` 200 · `admin.` / `partner.` 307 (ไปหน้า login) · `www.` 308 → `getpack.co`

---

## 11. ข้อมูลตั้งต้นของ Production

> ❌ **ห้ามรัน** บน prod: `run.js uat`, `run.js dev`, `uat-style-fixture.js`, `uat:populate`, และห้ามตั้ง `UAT_TARGET_CONFIRM` / `UAT_SEED_CONFIRM`
> (มี guard อยู่แล้ว แต่ไม่ควรพึ่ง guard)

ตัวรันสคริปต์บนเครื่อง = service `migrate` (image ของ api, secret ชุดเดียวกัน, heap 1 GB):
```bash
sudo bash -c 'source /opt/collective/platform/bin/lib.sh; compose_product getpack run --rm --no-deps migrate node <script> …'
```

### 11.1 Reference seed (ครั้งเดียว — รันซ้ำได้ไม่เสียหาย)
```bash
sudo install -m 600 /dev/null /root/getpack-seed.env      # ใส่ SEED_ENTITY_* ของบริษัทจริง (บรรทัดละ KEY=value)
sudo bash -c '
source /opt/collective/platform/bin/lib.sh; args=()
while IFS= read -r l; do [[ $l =~ ^[A-Z_]+= ]] || continue; k=${l%%=*}; v=${l#*=}; v=${v%\"}; v=${v#\"}; args+=(-e "$k=$v"); done < /root/getpack-seed.env
compose_product getpack run --rm --no-deps "${args[@]}" migrate node dist/prisma/seed/run.js reference'
sudo rm -f /root/getpack-seed.env
```
ได้: entity, settings, roles/permissions, approval policies, notification templates/routes, ผังบัญชี, posting rules, ฯลฯ

### 11.2 ผู้ใช้จริง
reference seed **ไม่สร้าง** staff user → สร้าง **Superadmin คนแรก** ด้วย `scripts/create-superadmin.ts`
(ทำงานได้ครั้งเดียวต่อ environment: ปฏิเสธถ้ามี superadmin ที่ active อยู่แล้ว; เขียน audit `iam.user_created` + `iam.role_granted`
และ event ใน transaction เดียว, actor = `system:scripts.create-superadmin`)

```bash
# dry run ก่อน แล้วค่อย --confirm ; รหัสผ่านสุ่ม 24 ตัวอักษร แสดงครั้งเดียว → เก็บเข้า password manager ทันที
sudo bash -c 'source /opt/collective/platform/bin/lib.sh
compose_product getpack run --rm --no-deps migrate node dist/scripts/create-superadmin.js --email owner@getpack.co --name "ชื่อจริง"'
sudo bash -c 'source /opt/collective/platform/bin/lib.sh
compose_product getpack run --rm --no-deps migrate node dist/scripts/create-superadmin.js --email owner@getpack.co --name "ชื่อจริง" --confirm'
```
(กำหนดรหัสผ่านเองได้ด้วย `-e SUPERADMIN_PASSWORD=…` ≥ 16 ตัว — แต่จะไปค้างใน shell history; แบบสุ่มดีกว่า)

> ⚠️ getpack-api ยัง**ไม่มี** flow เปลี่ยน/รีเซ็ตรหัสผ่าน staff (PROGRESS: "password reset … not asked for yet")
> — รหัสผ่านที่ได้จึงเป็นรหัสถาวร เก็บให้ดี และควรทำ flow นี้ก่อนมีผู้ใช้หลายคน

จากนั้น Superadmin สร้างคนอื่นผ่าน `/v1/admin/users` (เคารพ SoD — คนให้สิทธิ์ต้องถือสิทธิ์นั้นอยู่) — **ห้ามใช้บัญชี `*@example.invalid`**

### 11.2.1 Settings
ทบทวนค่าที่ seed ตั้งเป็น `proposed` ใน `getpack-api/docs/launch/SETTINGS-REVIEW.md` ให้ Superadmin ยืนยัน/แก้ผ่าน `/v1/admin/settings` ก่อนเปิดขาย

### 11.3 Style library (กระบวนการจริง)
1. Prepress import: `node dist/scripts/styles-import.js docs/design-tool/style-library-master.json --confirm --as <prepress จริง>`
   (+ `--recipes <bundle>`) → การเปลี่ยนแปลงไปรออนุมัติ `style_library_change` (Prepress → Marketing)
2. Partner Manager บันทึก **site visit จริง** ของโรงงาน → โรงงาน propose capability → Partner Manager verify (maker-checker)
3. Publishability คำนวณใหม่อัตโนมัติ (ต่อการเปลี่ยนแปลง) และทุกคืน 03:15 (prod เปิด 24×7 จึงรันได้ — ต่างจาก UAT)

### 11.4 รูป
รูปทุกไฟล์ผ่าน **ClamAV** (`CLAMAV_HOST=clamav`) — ไม่มี clamd = ไฟล์ค้าง `pending` และไม่ถูกเสิร์ฟ
```bash
R() { compose_product getpack run --rm --no-deps migrate node "$@"; }      # ภายใน sudo bash -c 'source …/lib.sh; …'
R dist/scripts/styles-photos.js          <manifest.json> --confirm --as <staff ที่มี catalog.manage>
R dist/scripts/catalog-product-photos.js <manifest.json> --confirm --as <staff ที่มี catalog.manage>
R dist/scripts/cms-home-photos.js        <manifest.json> [--template name=PK-…] --publish --confirm --as <staff ที่มี cms.manage>
```
- manifest + ไฟล์ต้องอยู่ใน image (`public/media/…`) หรือ mount เข้า container — manifest ของ UAT ใช้กับ prod **ไม่ได้**
- ทุกสคริปต์ dry-run ถ้าไม่ใส่ `--confirm`, รันซ้ำได้ (ข้ามของที่มีแล้ว)
- ตรวจ: `select scan_status, count(*) from file_objects group by 1` → `clean` ทั้งหมด
- หน้าร้าน cache: home content 15 นาที, catalogue 5 นาที → อยากเห็นทันที `compose_product getpack up -d --no-deps --force-recreate web`
- การ์ด "แบบกล่อง" หน้า home: รูป CMS (`templates.<code>`) → รูปของ style → dieline

---

## 12. ตรวจรับหลังขึ้นระบบ (go-live checklist)

- [ ] `https://getpack.co`, `www`, `admin`, `partner`, `api/health`, `platform/healthz` — TLS valid ทุกชื่อ
- [ ] login staff ได้, สร้างผู้ใช้ได้, สิทธิ์ตาม role
- [ ] ลูกค้า: OTP SMS ถึงจริง, LINE Login, Google/Apple (Firebase)
- [ ] อีเมลจาก SES ถึง inbox ภายนอก (ไม่ใช่ spam) — ตรวจ DKIM=pass, SPF=pass, DMARC=pass ใน header
- [ ] upload artwork → `clean` → ดาวน์โหลดได้; ไฟล์ EICAR → `infected` และถูกลบ
- [ ] PDF (worker/Chromium) ออกได้, ฟอนต์ไทยถูก
- [ ] web push (VAPID), แจ้งเตือน LINE
- [ ] Payment: QR 30 / 2C2P จ่ายจริงยอดเล็ก → `confirmed`, refund 2C2P ได้, slip flow (Finance หรือ Slip2Go) ผ่าน — แล้วค่อยเปิด flag (§6.1)
- [ ] Grafana: metrics + logs `env="prod"` ครบ, alert ทดสอบยิงถึง
- [ ] pgBackRest: full backup แรก ok; **restore drill** ผ่าน (§13)
- [ ] EBS snapshot (DLM 02:00) ขึ้นใน console
- [ ] `docker stats` นิ่ง 24 ชม. (api < 1 GB)
- [ ] ลบ `~/.collective-secrets/prod/` หลังย้ายเข้า password manager

---

## 13. Day-2: งานประจำ

| งาน | วิธี |
|---|---|
| Deploy api | push main → CI → UAT อัตโนมัติ → ทดสอบ → **Promote** (component `api`) |
| Deploy web | push main → UAT; prod = tag `vX.Y.Z` (build ด้วย args ของ prod) |
| Rollback | อัตโนมัติเมื่อ health ไม่ผ่าน; เอง: `sudo /opt/collective/platform/bin/rollback.sh getpack api\|web` |
| Platform config (Caddy, Alloy, ClamAV, Postgres conf) | แก้ใน `platform/**` → push → Platform deploy; service ที่ไฟล์ config เปลี่ยนจะถูกสร้างใหม่เอง (label `collective.config`) — **postgres restart ~10–20 วิ** เมื่อ conf ของมันเปลี่ยน |
| เปลี่ยน hostname | `platform/caddy/sites.prod.yml` → push (hostname `.example` จะถูกข้าม) |
| Secret rotate | แก้ Secrets Manager → deploy component นั้นซ้ำ (`deploy-product.sh getpack api <same-tag>`) |
| Backup | pgBackRest full อาทิตย์ / diff ทุกวัน 01:30, WAL ทุก 5 นาที → `s3://collective-prod-backups/pgbackrest/prod` |
| Restore drill (รายเดือน) | บน UAT: `sudo /opt/collective/platform/bin/restore-drill.sh prod` |
| Memory | Grafana `container_memory_working_set_bytes{env="prod", name=~"getpack-.*"}` — ถ้า api ขึ้นไม่หยุด = leak |
| Shell | `aws ssm start-session --target <instance-id>` |

Memory budget ของเครื่อง 16 GB (limit): caddy 256M · postgres 4G · valkey 512M · emqx 512M · clamav 2G · alloy 384M (≈7.7 GB)
+ getpack: web 512M · api 1.5G (heap 1024) · worker 2G (heap 1280) ≈ 4 GB → เหลือ ~3.5 GB ให้ getproperty/getbuild (เริ่มตึง — ดู CPU/RAM ก่อนเพิ่ม product)

---

## 14. ปัญหาที่เคยเจอบน UAT และวิธีแก้

แก้ในโค้ดแล้วทั้งหมด — ไว้ใช้วินิจฉัยถ้าเจออาการคล้ายกัน

| อาการ | สาเหตุ | แก้แล้วที่ |
|---|---|---|
| `InvalidClientTokenId` / S3 403 ผิด account | ใช้ credentials ผิด account / region ยังไม่ enable | `AWS_PROFILE=collective`, `envs/account.txt` guard; enable region `ap-southeast-7` |
| SCP ปฏิเสธ ap-southeast-7 / ap-southeast-1 | Organizations SCP region restriction | แก้ SCP ใน management account ให้ทั้งสอง region |
| `Invalid AWS Region` ที่ backend | Terraform ไม่รู้จัก ap-southeast-7 | `skip_region_validation = true` |
| SES `UnknownOperation` | ap-southeast-7 ไม่มี SES | provider alias `aws.ses` = ap-southeast-1; app ใช้ `SES_REGION` |
| systemd ค้างตอน bootstrap | service รัน bootstrap แล้ว bootstrap สั่ง start ตัวเอง | `systemctl enable` (ไม่ `--now`) |
| pgBackRest หา config ไม่เจอ / spool permission | path default ของ image / uid | `PGBACKREST_CONFIG`, chown `/data/pgbackrest-spool` 1000 |
| Alloy crash ตอนไม่มี Grafana | ค่าว่าง | profile `observability` เปิดเมื่อมี secret |
| Loki HTTP 405 | URL ไม่มี `/loki/api/v1/push` | ใส่ path ใน secret |
| EMQX `post_to_push_gateway_failed` | `EMQX_PROMETHEUS__ENABLE` = push gateway | ลบออก (Alloy scrape `/api/v5/prometheus/stats`) |
| series ซ้ำทุกครั้งที่สร้าง Alloy ใหม่ | instance = container id | relabel instance คงที่ |
| `sts:AssumeRoleWithWebIdentity` denied | GitHub ส่ง sub แบบ immutable `repo:Org@346483067/repo@<id>:…` | trust รับทั้งสองรูปแบบ (`github_org_id`) |
| `Credentials could not be loaded` | job ใช้ environment ที่ไม่มี var (`terraform-apply`) | สร้าง environment + `AWS_TERRAFORM_ROLE_ARN` |
| Required reviewers HTTP 422 | GitHub Free + private repo | §1.2 |
| api กับ web คนละ tag | สอง repo ship แยกกัน | `deploy-product.sh <product> <component> <tag>`, `API_TAG`/`WEB_TAG` |
| migrate ไม่รัน (`--no-migrate` ตลอด) | expression `inputs.migrate && '' \|\| …` ('' = falsy) | `!inputs.migrate && '--no-migrate' \|\| ''` |
| `prisma migrate` ไม่มีใน image | prisma เป็น devDependency | stage `prisma-cli` → `/opt/prisma-cli` + `prisma.deploy.config.ts` |
| worker ถูก rollback | healthcheck port 3001 ที่ไม่มีจริง | worker ไม่มี healthcheck |
| web edge check TLS error (`admin-uat`) | DNS ยังไม่ครบ → ไม่มี cert | เพิ่ม DNS → `caddy reload --force` |
| Caddy retry ACME `.example` ตลอด | hostname placeholder | render-sites ข้าม `.example` |
| แก้ Caddyfile แล้วไม่มีผล | bind-mount ไฟล์เดี่ยว + git สร้าง inode ใหม่ | label `collective.config` = hash → recreate |
| api OOM วนรีสตาร์ท → web 500 / Caddy 504 | heap default ≈ ครึ่งของ 640M | api 1.5G + `--max-old-space-size=1024` |
| ไฟล์ upload `pending` ตลอด | real mode ไม่มี scanner | ClamAV (`clamav/clamav-debian:1.4` — image Alpine ไม่มี arm64) + `ClamdScanner` |
| สคริปต์ใน `migrate` → `S3_BUCKET failed isString` | migrate ไม่มี env ของ S3 | เพิ่ม `S3_BUCKET`, `AWS_REGION`, `TZ`, `CLAMAV_HOST` |
| `uat-style-fixture` timeout 5 s | recompute ทั้งหมดใน transaction default | timeout 120 s |
| รูปไม่ขึ้นหลัง import | Next data cache (15/5 นาที) | recreate web หรือรอ |
| การ์ดหน้า home เป็น dieline | ใช้แค่รูป CMS | fallback รูปของ style |

---

## 15. ค่าอ้างอิง

| รายการ | ค่า |
|---|---|
| AWS account (workload) | `231438713843` — profile `collective` |
| Region | `ap-southeast-7` (SES: `ap-southeast-1`) |
| State bucket | `collective-tfstate-231438713843` |
| Terraform role (GitHub) | `arn:aws:iam::231438713843:role/collective-gha-terraform` |
| Deploy role | UAT `collective-uat-gha-deploy` · **prod `collective-prod-gha-deploy`** |
| GitHub org / id | `Collective-Group-Thailand` / `346483067` |
| Secrets prefix | `collective/prod/` (`platform/*`, `getpack/app`) |
| ECR | `231438713843.dkr.ecr.ap-southeast-7.amazonaws.com/getpack/{api,web}` (`:sha-xxxxxxx`, `:uat`, `:prod`) |
| เครื่อง: path | repo `/opt/collective/infra` · platform `/opt/collective/platform` · env `/etc/collective/platform.env` · secrets `/run/collective/` · state `/var/lib/collective/getpack{,.hosts}.env` · log `/var/log/collective/platform.log` |
| Postgres | container `platform-postgres-1`, DB `getpack` (+`getpack_shadow`), role `getpack` |
| UAT (อ้างอิง) | `i-08a473d0ec4946339`, EIP `43.211.94.171` |

**สคริปต์บนเครื่อง** (`/opt/collective/platform/bin/`): `bootstrap.sh` · `deploy-product.sh <p> <api|web> <tag> [--no-migrate]` ·
`rollback.sh <p> <api|web>` · `healthcheck.sh <p> <api|web>` · `fetch-secrets.sh <platform|p>` · `render-sites.sh` · `restore-drill.sh` · `wake.sh`
