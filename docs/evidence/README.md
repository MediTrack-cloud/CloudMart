# CloudMart — Evidence Capture Guide

Everything in this folder is the **live proof** the brief's §12 Evidence Checklist and §9 demo
checkpoints require but that cannot live in source. For each item below you get:

- **File** — the exact filename to save it as (drop it in the matching sub-folder).
- **Capture** — the real command / console path to produce it.
- **Simulate** — how to fake/trigger it when there's no live traffic (sample findings, load tests, 404s).

> Most CLI evidence is produced automatically by [`capture.sh`](capture.sh) once the stack is up
> (`./deploy.sh -e prod`, then `aws eks update-kubeconfig --name cloudmart-prod --region us-east-1`).
> Screenshots (console views) you still take by hand — the path is given per item.

## Naming convention

```
EV-<AREA>-<NN>-<slug>.<ext>
```
- `<AREA>` = INFRA · SEC · CICD · OBS · COST · DR
- `<NN>`   = zero-padded order (01, 02, …)
- `<ext>`  = `.txt` for terminal output · `.png` for screenshots · `.md` for written notes

Real resource names baked into the commands (from the Terraform/K8s in this repo):

| Thing | Name |
|-------|------|
| EKS cluster | `cloudmart-prod` / `cloudmart-staging` |
| Namespace | `cloudmart-prod` |
| RDS instance id | `cloudmart-prod` (db `cloudmart`, port 5432) |
| SQS queue | `cloudmart-orders-prod` |
| CloudWatch dashboard | `CloudMart-prod` and `CloudMart-prod-Detailed` |
| Budget | `cloudmart-monthly-prod` |
| Velero schedule | `cloudmart-prod-daily` (ns `velero`) |
| Ingress / ALB | `cloudmart-ingress` (ns `cloudmart-prod`) |
| ECR repos | `cloudmart/<service>` |
| ServiceAccounts (IRSA) | `product-service`, `order-service`, `user-service`, `notification-service` |

Set once per shell:
```bash
export ENV=prod NS=cloudmart-prod AWS_REGION=us-east-1
aws eks update-kubeconfig --name cloudmart-$ENV --region $AWS_REGION
```

---

## INFRA — Infrastructure & Networking → `infra/`

| File | Capture | Simulate |
|------|---------|----------|
| `EV-INFRA-01-kubectl-get-nodes.txt` | `kubectl get nodes -o wide \| tee infra/EV-INFRA-01-kubectl-get-nodes.txt` | If no cloud cluster, run the same against a local `kind` cluster (see *Local simulation* below) — shows ≥2 nodes. |
| `EV-INFRA-02-pods-prod.txt` | `kubectl get pods -n $NS -o wide \| tee infra/EV-INFRA-02-pods-prod.txt` | Same kind cluster with `kubectl apply -k k8s/overlays/staging` minus cloud-only bits. |
| `EV-INFRA-03-vpc-console.png` | **Console:** VPC → Your VPCs → `cloudmart-prod` → screenshot CIDR `10.0.0.0/16` + Resource map. | **CLI proof instead:** `aws ec2 describe-vpcs --filters Name=tag:Project,Values=cloudmart` |
| `EV-INFRA-04-subnets-console.png` | **Console:** VPC → Subnets, filter `cloudmart` → show 6 subnets (public/app/data × 2 AZ). | `aws ec2 describe-subnets --filters Name=tag:Project,Values=cloudmart --query 'Subnets[].{CIDR:CidrBlock,AZ:AvailabilityZone,Name:Tags[?Key==\`Name\`]\|[0].Value}' --output table` |
| `EV-INFRA-05-alb-console.png` | **Console:** EC2 → Load Balancers → the `k8s-cloudmart…` ALB → Listeners (80/443) + target groups healthy. | `kubectl get ingress -n $NS` (shows ALB DNS) + `aws elbv2 describe-load-balancers` |
| `EV-INFRA-06-db-private-nc.txt` | From your **laptop (outside the VPC)**: `nc -zv -w 5 $(aws rds describe-db-instances --db-instance-identifier cloudmart-$ENV --query 'DBInstances[0].Endpoint.Address' --output text) 5432 \|& tee infra/EV-INFRA-06-db-private-nc.txt` — must **time out / fail** (proves DB is private). | This *is* the proof — the timeout is the evidence. Also screenshot the RDS "Publicly accessible: No" flag. |

---

## SEC — Security → `security/`

| File | Capture | Simulate |
|------|---------|----------|
| `EV-SEC-01-networkpolicy.txt` | `kubectl get networkpolicy -n $NS \| tee security/EV-SEC-01-networkpolicy.txt` (add `kubectl describe networkpolicy default-deny -n $NS` for detail). | Works on any cluster with the manifests applied (kind included). |
| `EV-SEC-02-irsa-binding.png` | **Console:** IAM → Roles → `cloudmart-prod-product-service-irsa` → Trust relationships (shows the OIDC + SA condition). **+ CLI:** `kubectl get sa product-service -n $NS -o yaml \| tee security/EV-SEC-02-irsa-binding.txt` (shows `eks.amazonaws.com/role-arn`). | The `kubectl get sa … -o yaml` annotation is enough if you can't screenshot the console. |
| `EV-SEC-03-guardduty-finding.png` | **Console:** GuardDuty → Findings → open the generated finding → screenshot severity + detail. | **Generate one:** `DET=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text); aws guardduty create-sample-findings --detector-id $DET --finding-types "UnauthorizedAccess:EKS/MaliciousIPCaller.Custom"` — appears in ~1 min. |
| `EV-SEC-04-guardduty-response.md` | Written note: triage steps you took (SNS email → block offending IP at WAF → tighten NetworkPolicy). | n/a — this is narrative for report §3. |

---

## CICD — Pipelines → `cicd/`

| File | Capture | Simulate |
|------|---------|----------|
| `EV-CICD-01-actions-run.png` | **GitHub → Actions** → latest `CI — Build, Scan, Push` run → screenshot the green job graph (test → build → Trivy → push → validate). | Push any commit to a `feature/*` branch to trigger CI (it runs on `branches: ["**"]`). |
| `EV-CICD-02-staging-change.png` | Demo checkpoint 5: change homepage text → push to `develop` → screenshot the `cd-staging` run **and** the staging site showing the new text. | Edit `services/frontend/src/App.js`, commit to `develop`, watch `cd-staging.yml`. |

---

## OBS — Autoscaling & Observability → `observability/`

| File | Capture | Simulate |
|------|---------|----------|
| `EV-OBS-01-hpa-scaling.txt` | In one pane: `kubectl get hpa -n $NS -w \| tee observability/EV-OBS-01-hpa-scaling.txt`. In another, drive load (see Simulate). Capture replicas climbing 2→…→6. | **Load test:** `ALB=$(kubectl get ingress cloudmart-ingress -n $NS -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); hey -z 3m -c 100 http://$ALB/api/products` (or `k6 run`). |
| `EV-OBS-02-dashboard.png` | **Console:** CloudWatch → Dashboards → `CloudMart-prod` → screenshot all widgets (CPU, memory, request rate, error rate, queue depth, DB connections). | Generate traffic with the same `hey` command so the graphs have data. |
| `EV-OBS-03-404-logs-insights.png` | Trigger: `curl -s -o /dev/null -w '%{http_code}\n' http://$ALB/api/this-does-not-exist` → then **CloudWatch → Logs Insights**, log group `/cloudmart/frontend/prod`, run the saved query, screenshot the 404 row. | The curl above *is* the simulation — hit any nonexistent path. |

---

## COST — FinOps → `cost/`

| File | Capture | Simulate |
|------|---------|----------|
| `EV-COST-01-cost-explorer.png` | **Console:** Billing → Cost Explorer → filter `Project=cloudmart`, Group by tag `Environment`, daily granularity → screenshot. | Needs ≥24–48 h of real spend. No live account? Use **AWS Pricing Calculator** with the m7i-flex.large + RDS + NAT line items and screenshot that as the estimate. |
| `EV-COST-02-budget-alert.png` | **Console:** Billing → Budgets → `cloudmart-monthly-prod` → screenshot the threshold + email alert config. | `aws budgets describe-budgets --account-id $(aws sts get-caller-identity --query Account --output text)` proves it exists immediately after apply. |
| `EV-COST-03-unit-economics.png` | Slide built from `docs/cost-analysis.md` §3: **$40.10 / 1,000 orders** (prod $401 ÷ 10k orders). | n/a — derived from the cost doc; just render it as a slide. |

---

## DR — Disaster Recovery → `dr/`

| File | Capture | Simulate |
|------|---------|----------|
| `EV-DR-01-rds-backups.png` | **Console:** RDS → `cloudmart-prod` → Maintenance & backups → screenshot "Automated backups: Enabled, 7 days, PITR". **+ CLI:** `aws rds describe-db-instances --db-instance-identifier cloudmart-$ENV --query 'DBInstances[0].{Retention:BackupRetentionPeriod,Window:PreferredBackupWindow}' \| tee dr/EV-DR-01-rds-backups.txt` | The CLI output proves retention=7 right after apply. |
| `EV-DR-02-pitr-restore.png` | Restore to a **test** instance (never prod): `aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier cloudmart-$ENV --target-db-instance-identifier cloudmart-pitr-test --use-latest-restorable-time` → screenshot it reaching `available`. Tear down after. | Same command — it's a real, safe drill on a throwaway instance. |
| `EV-DR-03-velero.txt` | `kubectl get schedule -n velero \| tee dr/EV-DR-03-velero.txt; velero backup get; velero restore create --from-backup cloudmart-prod-daily-<ts> --include-namespaces cloudmart-prod` | Trigger an on-demand backup first: `velero backup create dr-drill --include-namespaces cloudmart-prod`, then restore from it. |

---

## Local simulation (no AWS account at all)

For the **K8s-object** evidence (nodes, pods, networkpolicy, hpa) you can produce real screenshots
on a throwaway local cluster — useful for rehearsal:

```bash
kind create cluster --name cloudmart-sim --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes: [ {role: control-plane}, {role: worker}, {role: worker} ]   # -> 2 worker nodes for EV-INFRA-01
EOF

kubectl create ns cloudmart-prod
kubectl apply -f k8s/base/network-policies/ -n cloudmart-prod      # EV-SEC-01
# HPA demo needs metrics-server:
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

⚠️ Pods won't reach **Running** on kind because they pull from your private ECR and bind IRSA/External
Secrets — so `EV-INFRA-02` (pods Ready) and the dashboard/cost/DR items still need the real deploy.
Use kind only to rehearse the `get nodes / networkpolicy / hpa` captures.

---

## One-shot capture

```bash
export ENV=prod AWS_REGION=us-east-1
./docs/evidence/capture.sh           # writes every CLI-based EV-*.txt into the sub-folders
```
Then take the console screenshots flagged `.png` above and tick them off in
[`../../TODO-AUDIT.md`](../../TODO-AUDIT.md).
