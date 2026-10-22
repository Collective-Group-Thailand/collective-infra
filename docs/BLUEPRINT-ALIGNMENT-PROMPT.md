# Prompt: align a product blueprint with Collective's infrastructure decisions

วางส่วน **A (common)** ก่อน แล้วต่อด้วย **B** ของ product นั้น ใน session ที่ถือ blueprint/repo ของ product

---

## A. Common prompt (ใช้กับทุก product)

```
You are updating the <PRODUCT> blueprint (and, where a repo exists, its docs/decisions.md and ADRs) so that
every infrastructure, deployment and operations statement matches Collective Group's single source of truth:
the `collective-infra` repository (~/Collective/collective-infra — read PLAN.md and README.md first if you
have file access; otherwise use the decisions below verbatim).

## Locked infrastructure decisions (2026-10-21) — do not re-open, do not propose alternatives

1. Cloud & region: AWS only, region ap-southeast-7 (Thailand). No GCP, no Firebase, no Singapore.
2. Compute: EC2 only, forever. Each environment is ONE Graviton (arm64) EC2 box running docker compose.
   Scaling = resize the box, then add boxes (worker box, DB box, GPU box). Explicitly NOT used, now or
   later: RDS, ElastiCache, ECS/Fargate, EKS/Kubernetes, Cloud Run, Lambda for app logic, ArgoCD.
3. Shared platform per box (compose project `platform`): Caddy (ingress + auto-TLS), PostgreSQL 18 via
   `timescale/timescaledb-ha:pg18` (TimescaleDB + pgvector + pgBackRest included), Valkey 8 (BullMQ/cache),
   EMQX 5.8 (MQTT, mTLS per device), Grafana Alloy (metrics/logs/traces → Grafana Cloud).
4. Isolation: one database + one role per product inside the shared PostgreSQL; one S3 assets bucket,
   one Secrets Manager secret, one SES identity, one ECR repo per image, per product and per environment.
   No cross-database queries. Cross-product integration = outbox → HTTP webhook (same box) or SNS/SQS
   (separate boxes). No Pub/Sub, no Kafka.
5. Environments: `uat` (t4g.large, EventBridge-scheduled 08:00–20:00 Mon–Fri Asia/Bangkok) and `prod`
   (t4g.xlarge 24×7). No `dev` cloud environment: dev is local docker compose.
6. Data safety: pgBackRest full (Sun) + diff (daily) + WAL archive (archive_timeout 300s → RPO ≤ 5 min) to
   S3; daily EBS snapshot (DLM) with cross-region copy; monthly restore drill. RTO target 30 min via restore.
   There is no managed failover; HA, if ever needed, is a streaming replica on a second EC2 "DB box".
7. Access: no SSH. SSM Session Manager / Run Command only. No long-lived IAM keys anywhere.
8. CI/CD: GitHub Actions + OIDC → ECR (arm64 images) → SSM Run Command runs
   `platform/bin/deploy-product.sh <product> <tag>` (pull, `prisma migrate deploy`, up, healthcheck,
   auto-rollback). `main` → UAT; tag `v*.*.*` or manual promote → prod with GitHub Environment approval.
   Product repos call the reusable workflows `reusable-build-push.yml` and `reusable-deploy.yml` from
   collective-infra. No Terraform inside product repos.
9. Observability: OpenTelemetry (traces) + Prometheus `/metrics` + pino JSON logs → Alloy → Grafana Cloud
   Free; Sentry for app errors; CloudWatch only for host alarms and EC2 auto-recovery.
10. Secrets: AWS Secrets Manager, path `collective/<env>/<product>/app` (flat JSON of env vars), read at
    deploy time into the container env. Nothing in GitHub secrets, repo files or tfvars.
11. Image contract every product must satisfy: arm64 image; API `/health` on :3000 and `/metrics`;
    web `/api/healthz` on :3000; worker health on :3001; migrations = `npx prisma migrate deploy` inside
    the api image; OTLP to `$OTEL_EXPORTER_OTLP_ENDPOINT`; S3 via instance role (no keys); DB via
    `DATABASE_URL` with a pool ≤ 15 (api) / 10 (worker) because PostgreSQL max_connections is shared.
12. PDF rendering: only ONE Chromium runs on the box (getpack worker). Other products must either render
    PDFs through the shared `pdf-render` BullMQ queue (HTML in → S3 key out) or justify in an ADR why they
    need their own Chromium (and budget 1.5 GB for it).
13. AI/ML: external API inference only (Claude / Gemini / Typhoon OCR). Python AI workers are allowed but
    run on a separate EC2 "worker box" (from ~Mar 2027), connect to the main box's PostgreSQL/Valkey over
    the private subnet, and are deployed with the same compose + SSM pattern. Self-hosted models (YOLO,
    Whisper) only on an EC2 GPU box started for batch jobs — not before 2028 and only with an ADR.
14. Memory budget on the shared 16 GB prod box (hard limits in compose): platform ≈ 6 GB; getpack 3.2 GB;
    getproperty ≈ 1.8 GB; getbuild ≈ 1.5 GB. A product that needs more must state it and the trigger for
    moving to its own box.

## What to change in the blueprint

- Rewrite the Infrastructure / Deployment / DevOps / Hosting sections to state the decisions above (short)
  and reference collective-infra for detail. Delete any architecture diagram or cost table that assumes
  managed services; replace with "runs on the shared Collective box; see collective-infra/PLAN.md".
- Replace every mention of: Cloud Run / Cloud SQL / GCS / Memorystore / Pub/Sub / GKE / Cloud Trace /
  Firebase / ap-southeast-1 / ECS Fargate / RDS / ElastiCache / Kubernetes / ArgoCD / MinIO with the
  corresponding item in the list above (GCS → S3, Memorystore → Valkey, Pub/Sub → outbox+webhook or
  SNS/SQS, Cloud SQL → shared PostgreSQL on the box, etc.).
- Keep product scope, modules, phases and business content unchanged — this is an infrastructure
  alignment only. Do not downgrade requirements (RPO/RTO, retention, PDPA): map them onto the mechanisms
  above and say so explicitly.
- Add a subsection "Infrastructure asks from collective-infra" listing, with the phase/date each is
  needed, anything this product needs beyond the shared platform (extra buckets, ports, worker box, GPU,
  volume growth, new MQTT topics, cron jobs). Be specific and quantified (GB, msgs/s, req/min, rows/day).
- Update the memory budget line for this product (api/web/worker limits) and confirm the image contract
  (item 11) or list the gaps as tasks.
- Where a repo exists, mirror the changes into docs/decisions.md (new decision rows superseding the old
  ones — never delete history) and the relevant ADR (status: Superseded/Amended with date 2026-10-21).
- Finish with a short changelog: which sections changed, which decisions were superseded, and open
  questions for the founder (max 5).
```

---

## B. Product-specific appendix (ต่อท้าย A)

### B1. getbuild (blueprint v1.0, 2026-10-20)

```
Product-specific corrections for getbuild:
- Section "Infrastructure": currently AWS ap-southeast-1 + ECS Fargate + RDS + ElastiCache + CloudFront
  + "Terraform under infra/". Change to the shared box in ap-southeast-7; keep CloudFront only for the
  Electron auto-update feed and static assets. Remove `infra/` Terraform from the monorepo plan.
- Realtime: Socket.IO stays inside the single getbuild-api container (one replica → no Redis adapter
  needed yet); note the trigger (second api replica) for adding the Valkey adapter.
- Thai text segmentation (pythainlp) and OCR/AI takeoff are Python → they run on the worker box (item 13),
  not inside the NestJS image. Phase 1 must work without them.
- Infrastructure asks to list, with dates: `releases` bucket + CloudFront (Electron stable/beta channels)
  — P1 month 3–8; `archive` bucket with S3 Object Lock (e-Tax signed docs 5 y, audit log 10 y) — P1 when
  e-Tax goes live; S3 lifecycle for site photos (~1,000/day/site, quantify GB/month at 25 sites); public
  API rate limits (600–6,000 req/min/tenant) enforced in NestJS throttler, not at the edge.
- RPO 5 min / RTO 2 h: map to pgBackRest WAL archiving + restore drill; "daily cross-region snapshot" →
  DLM cross-region copy. Do not mention RDS PITR.
- getbuild Build modules M1–M16 must be synced into this blueprint's Build section (the getbuild doc
  still lists them separately). Reconcile the two phase plans into one.
- Memory budget: api 512 MB, worker 1 GB, no web container (Next.js back-office is SSR → yes it IS a
  container; correct the collective-infra assumption if getbuild web needs SSR, and budget 512 MB for it).
```

### B2. getproperty (blueprint 2026-10-16 + repo docs/decisions.md, ADR-0001)

```
Product-specific corrections for getproperty:
- The blueprint and D-160/D-162 assume GCP (Cloud Run, Cloud SQL without timescaledb, GCS, Memorystore,
  Pub/Sub, GKE for EMQX). Founder decided 2026-10-21: AWS, same pattern as getpack. Supersede D-160 and
  D-162; amend ADR-0001: TimescaleDB IS available (timescaledb-ha image) — keep the portable
  range-partitioned tables as the baseline but enable the hypertable/continuous-aggregate migration in
  prod, and use compression for `smart.telemetry_point` after 30 days.
- EMQX is the shared platform broker, not a per-product GKE deployment. Document the authn/authz contract
  the platform needs from getproperty-api: EMQX HTTP authn (client cert CN `gw-<gatewayId>` + device JWT)
  and HTTP authz for topics `gp/v1/{gatewayId}/…`; CA chain for device certificates lives in Secrets
  Manager `collective/<env>/platform/device-ca`; getproperty-api issues/renews device certs (D-130,
  CR-003). State ports: 8883 mTLS public, 1883 internal only, 8083 ws behind Caddy.
- PDFs (bills, receipts, lease contracts, e-sign) → shared `pdf-render` queue (item 12). If a per-product
  Chromium is kept, raise the worker budget to 1.5 GB and say why.
- Python `getproperty-ai-workers` (meter OCR, STT, forecasting, RAG) are Phase 2 and run on the worker
  box; Phase 1 OCR uses the vision-model API adapter only.
- Quantify telemetry for the infrastructure asks: 15-min polling, ≤300 meters per RS485 bus, device
  targets 1 building → 500 → 10,000; give rows/day and GB/year at each KPI, and the data-volume growth
  request (120 → 250 GB) with its date.
- On-prem mini PC per building (getproperty-edge compose, store-and-forward) is unchanged — it is not
  cloud infrastructure; keep it, but remove any mention of GKE/Cloud IoT.
- Replace "Pub/Sub + REST callback" for cross-platform events with outbox → HTTP webhook; keep the
  integration_event / idempotency design.
```

### B3. getbuild (blueprint rev 48 — now the Build modules of getbuild)

```
Product-specific corrections for getbuild:
- getbuild is no longer a separate system (merged into getbuild 2026-10-20). Mark the blueprint as the
  "Build modules specification" that feeds the getbuild blueprint; remove the standalone repo plan
  (getbuild-web / getbuild-liff / getbuild-api / getbuild-ai-workers) and the GCP section (Cloud Run,
  GKE Autopilot, Cloud SQL, GCS, Memorystore). Infrastructure lives in getbuild's section.
- Keep the 16 modules / 5 phases, but express infrastructure asks per phase for getbuild's
  "Infrastructure asks" list: P2 AI Gateway + Python workers → worker box (Mar–Jun 2027); P3 M2 BOQ
  PDF/raster extraction → worker box CPU/RAM estimate; P4 Site IoT camera frames (1 frame / 10–30 min /
  camera) + drone orthomosaics → S3 volume estimate and lifecycle, EMQX topics via the shared broker;
  P5 self-hosted YOLO/Whisper → EC2 GPU box, batch only, ADR required.
- Drone photogrammetry: state that the engine is an external service/partner output (upload results),
  not self-hosted, unless an ADR says otherwise.
- "Event bus (Pub/Sub)" → outbox + HTTP webhook (same box) / SNS+SQS (separate boxes).
- Shared IoT ingestion via getproperty-edge and the platform EMQX stays as is.
```

### B4. getenergy (Platform Blueprint 2026-10-21)

```
Product-specific corrections for getenergy:
- Already AWS Thailand + EC2 compose + GitHub Actions + Grafana Cloud — confirm and reference
  collective-infra instead of restating. Remove the "exit criteria to ECS/EKS" paragraph: there is no
  ECS/EKS path; the scale path is bigger box → separate worker/DB boxes.
- Separate compute from day one is accepted: getenergy gets its own stack (`envs/_stack` with
  name_prefix `getenergy`): prod m7g.xlarge (Document Engine: PaddleOCR + LibreOffice headless + vision
  LLM; AI/RAG FastAPI; e-GP crawler; LME/FX ingestion), UAT t4g.large scheduled. Needed by G1 (month 3,
  ≈ Feb 2027). Give a memory budget per service (NestJS api/web per suite, Python document engine,
  AI/RAG service, workers) that fits 16 GB, or ask for m7g.2xlarge with justification.
- Identity: drop Keycloak as an option; custom OIDC + LINE Login like the other products.
- Object storage "S3-compatible" → S3 (instance role, presigned URLs). Redis → Valkey. Stripe → prefer the
  payment/e-Tax providers already chosen by getpack/getbuild (Omise/2C2P + the shared e-Tax SP).
- Cable Traceability (S1): 1M tags / 100k LINE verify scans in 12 months — quantify req/s on the public
  verify page and whether it needs CloudFront caching; it is the only public, unauthenticated, bursty
  endpoint in the group.
- O3/O4 meter data shares the getproperty IoT pipeline (EMQX + edge). State the cross-stack path:
  getproperty box EMQX → getenergy box over private VPC (SNS/SQS or MQTT bridge) and ask collective-infra
  for the SG rules.
- Single big-bang launch at month 18 stays; infrastructure asks still need dates per internal gate
  (G1 … G5) so UAT capacity exists one gate ahead.
```
