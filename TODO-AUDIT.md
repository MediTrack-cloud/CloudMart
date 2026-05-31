# CloudMart — Audit To-Do List

Findings from a full pass over git, code, infra, CI/CD, and the report against `requirements.md`.
Ordered by priority. Tick items as you resolve them.

---

## P0 — Fix before submission (graded / visible in viva)

- [x] **Branch naming violates the required strategy.** ✅ DONE — renamed all 5 on origin to `feature/*`:
  - `dev-madhura → feature/cicd-observability`, `dev-dilshan → feature/networking-infra`,
    `dev-asela → feature/k8s-gitops`, `dev-akila → feature/services-helm`, `dev-himasha → feature/security-frontend`.
  - Old `dev-*` remote branches deleted. Remote now: `main`, `develop`, `feature/*` only.
  - ⚠️ Teammates must re-sync: `git fetch --prune` then recreate their local branch from the new `feature/*` name.

- [x] **Report falsely claims `feature/*` is used.** ✅ Now TRUE after the rename — no text change needed
  (`docs/REPORT.md:139`, compliance matrix line). Assessor running `git branch -a` will see clean `feature/*`.

- [x] **Node instance type contradicts itself across ADR / cost / Terraform.** ✅ DONE — standardised on **m7i-flex.large**:
  - Terraform already deployed m7i-flex.large; aligned the stray staging default (`variables.tf` t3.small → m7i-flex.large).
  - Rewrote ADR-001 to justify m7i-flex.large and ADDED the previously-missing compute-optimised (c7i.large)
    and ARM (m7g.large) comparison options that §8.2 requires.
  - Updated all cost numbers: prod ~$401/mo, compute $213, unit econ $40.10/1000 orders, RI saving $621/yr.
  - Files: ADR-001, `docs/cost-analysis.md`, `REPORT.md` §1/§2.2/§5.1–5.4/§7, `README.md`, `INSTRUCTIONS.md`.

- [x] **Staging cost uses the same wrong node assumption.** ✅ DONE — recomputed to ~$253/mo (report) /
  ~$75/week (INSTRUCTIONS.md).

---

## P1 — Live evidence / screenshots to capture at deploy & demo
(Report marks these ✅ but they are NOT in the repo — needed for §12 Evidence Checklist + report appendices.)

> 📁 **Full runbook + commands + simulation + filenames:** [`docs/evidence/README.md`](docs/evidence/README.md).
> Run [`docs/evidence/capture.sh`](docs/evidence/capture.sh) after `./deploy.sh -e prod` to auto-produce every
> CLI-based `.txt`; then take the `.png` console screenshots. Save each into `docs/evidence/<area>/`.

### Infrastructure / networking → `docs/evidence/infra/`
- [ ] `EV-INFRA-01-kubectl-get-nodes.txt` — `kubectl get nodes` (2+ nodes)
- [ ] `EV-INFRA-02-pods-prod.txt` — `kubectl get pods -n cloudmart-prod`
- [ ] `EV-INFRA-03-vpc-console.png` — VPC layout (console)
- [ ] `EV-INFRA-04-subnets-console.png` — subnet layout (console)
- [ ] `EV-INFRA-05-alb-console.png` — load balancer (console)
- [ ] `EV-INFRA-06-db-private-nc.txt` — failed `nc` to RDS:5432 from outside the VPC

### Security → `docs/evidence/security/`
- [ ] `EV-SEC-01-networkpolicy.txt` — `kubectl get networkpolicy -n cloudmart-prod`
- [ ] `EV-SEC-02-irsa-binding.png` (+ `.txt`) — IRSA role-arn binding
- [ ] `EV-SEC-03-guardduty-finding.png` — GuardDuty finding (use `create-sample-findings`)
- [ ] `EV-SEC-04-guardduty-response.md` — written response action

### CI/CD → `docs/evidence/cicd/`
- [ ] `EV-CICD-01-actions-run.png` — GitHub Actions pipeline run
- [ ] `EV-CICD-02-staging-change.png` — staging deploy proof ("change appears in staging")

### Autoscaling / observability → `docs/evidence/observability/`
- [ ] `EV-OBS-01-hpa-scaling.txt` — `kubectl get hpa -w` scaling under `hey`/`k6` load
- [ ] `EV-OBS-02-dashboard.png` — CloudWatch dashboard with live metrics
- [ ] `EV-OBS-03-404-logs-insights.png` — 404 in Logs Insights results

### Cost → `docs/evidence/cost/`
- [ ] `EV-COST-01-cost-explorer.png` — daily spend grouped by `Environment` tag
- [ ] `EV-COST-02-budget-alert.png` — active budget alert
- [ ] `EV-COST-03-unit-economics.png` — unit-economics slide ($40.10 / 1,000 orders)

### Disaster recovery → `docs/evidence/dr/`
- [ ] `EV-DR-01-rds-backups.png` (+ `.txt`) — RDS automated backup enabled (7-day)
- [ ] `EV-DR-02-pitr-restore.png` — PITR restore to a **test** instance reaching `available`
- [ ] `EV-DR-03-velero.txt` — `kubectl get schedule -n velero` + a `velero restore` run

---

## P2 — Minor / housekeeping

- [ ] `requirements.md` (the checklist) is untracked in repo root — keep or move out, your call.
- [ ] `services/user-service/__pycache__/` exists on disk (gitignored/untracked — fine, leave or clean).
- [ ] Confirm `docs/.DS_Store` / root `.DS_Store` stay untracked (currently gitignored ✅).

---

## Verified GOOD (no action needed — recorded so nobody re-checks)

- Dockerfiles: all 5 multi-stage, non-root `USER`, `HEALTHCHECK`, correct minimal bases.
- `.dockerignore` present for all 5 services.
- K8s: 2 replicas prod / 1 notification, HPA 60% CPU 2→6 (product+order), PDBs, default-deny + 6 allow + DNS NetworkPolicies, External Secrets, Kyverno.
- CI: lint, test, build, Trivy CRITICAL gate, SHA-only image tags, kubeconform + kustomize validation.
- Order-throughput custom metric correctly wired (`order-service/src/index.js:226` JSON log ↔ metric filter pattern).
- Observability dashboard: all 6 mandatory widgets (CPU, memory, queue depth, RDS connections, request count, 5XX/error rate) + per-service log groups + flow-log rejected-traffic query.
- No secrets leaked: `.env`, `*.tfstate` gitignored & untracked; committed `terraform.tfvars` hold only config + owner email.
- 3 ADRs in `/docs/adr/`, Nygard format, correct filenames.
- 5 diagrams D1–D5 present (SVG + excalidraw), embedded in report.
