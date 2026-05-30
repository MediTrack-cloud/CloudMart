# CloudMart — Production-Grade Microservices on AWS EKS

**IS 4630 Cloud Infrastructure Management | University of Moratuwa**

CloudMart is a production-grade e-commerce platform deployed as five microservices on Amazon EKS. This implementation covers all mandatory, recommended, and distinction requirements from the assignment.

**Cloud Provider: AWS** | **Group: group-01** | **Owner: madhuraweerasooriye@gmail.com**

---

## Architecture Overview

```
Internet
   │
   ▼
[ALB + WAF v2]  ◀── Route 53 health-check failover → [S3 error page]
   │
   ▼ (HTTPS via ACM cert)
[Nginx Ingress — AWS Load Balancer Controller]
   │
   ├──▶ frontend (React/Nginx)
   ├──▶ product-service (Flask :8001) ──▶ DynamoDB (via VPC endpoint)
   ├──▶ order-service  (Express :8002) ──▶ product-service (ClusterIP)
   │                                   ──▶ SQS (orders queue)
   ├──▶ user-service   (Flask :8003)  ──▶ RDS PostgreSQL (private subnet)
   │                                   ──▶ Secrets Manager (via VPC endpoint)
   └──▶ notification-service ──▶ SQS (poll) ──▶ SES (send email)
```

All five services run in **cloudmart-prod** / **cloudmart-staging** namespaces with NetworkPolicy default-deny.

---

## Requirements Coverage

| Requirement | Status | Implementation |
|-------------|--------|---------------|
| 3-tier VPC (public/private-app/private-data) | ✅ M | `infra/modules/vpc` — /16 CIDR, 2 AZs |
| NAT Gateway (HA in prod, single in staging) | ✅ M | `single_nat_gateway` variable |
| Firewall rules (ALB, EKS nodes, RDS, Bastion) | ✅ M | 4 security groups with least-privilege rules |
| VPC endpoints (DynamoDB, S3, Secrets Manager, ECR) | ✅ R | Gateway + Interface endpoints |
| VPC Flow Logs + CloudWatch analytics query | ✅ D | `/cloudmart/vpc-flow-logs/{env}` |
| Dockerfiles (multi-stage, non-root, HEALTHCHECK) | ✅ M | All 5 services |
| .dockerignore for each service | ✅ M | All 5 services |
| Images pushed to ECR with lifecycle policy (10) | ✅ M | `infra/modules/ecr` |
| Trivy CRITICAL scan in CI | ✅ D | `.github/workflows/ci.yml` |
| Docker Compose for local dev | ✅ R | `docker-compose.yml` |
| EKS — 2+ replicas, resource limits, probes | ✅ M | All 5 Deployments |
| Rolling update (maxSurge:1, maxUnavailable:0) | ✅ M | All Deployments |
| HPA (product + order, 60% CPU) | ✅ M | `k8s/base/*/hpa.yaml` |
| KEDA (notification-service, SQS depth) | ✅ D | `k8s/keda/` |
| Namespaces (cloudmart-prod, cloudmart-staging) | ✅ M | `k8s/base/namespace.yaml` |
| ConfigMaps for non-sensitive config | ✅ M | `k8s/base/configmap.yaml` |
| Secrets via External Secrets Operator + Secrets Manager | ✅ M | `k8s/external-secrets/` |
| PodDisruptionBudgets | ✅ R | All production deployments |
| Cluster Autoscaler | ✅ R | `k8s/helm-values/cluster-autoscaler.yaml` |
| Default-deny NetworkPolicy | ✅ M | `k8s/base/network-policies/` |
| Explicit allow NetworkPolicy per path | ✅ M | 5 allow policies + DNS |
| IRSA per service (minimal permissions) | ✅ M | `infra/modules/iam` |
| IMDSv2 hardened (hop limit 1) | ✅ M | `infra/modules/eks` launch template |
| RDS encrypted at rest + SSL in transit | ✅ M | KMS + parameter group |
| GuardDuty + findings alert to SNS | ✅ R | `infra/modules/security` |
| WAF v2 with managed rules + rate limiting | ✅ R | `infra/modules/security` |
| Kyverno (no-root, ECR-only, require limits) | ✅ D | `k8s/security/` + `k8s/helm-values/kyverno.yaml` |
| CI: lint + test + build + Trivy + push | ✅ M | `.github/workflows/ci.yml` |
| CD staging (auto on develop) | ✅ M | `.github/workflows/cd-staging.yml` |
| CD prod (manual approval gate) | ✅ M | `.github/workflows/cd-prod.yml` |
| Argo Rollouts canary (product-service) | ✅ D | `k8s/argo-rollouts/` |
| ArgoCD GitOps | ✅ D | `k8s/argocd/` |
| Helm charts (all 5 services + umbrella) | ✅ R | `k8s/helm/` |
| CloudWatch Container Insights | ✅ M | EKS module |
| Log groups per service | ✅ M | `infra/modules/monitoring` |
| Dashboard (CPU, memory, SQS, RDS, ALB) | ✅ M | CloudWatch dashboard |
| product-service error rate alarm (>5% / 5min) | ✅ M | CloudWatch alarm + SNS |
| Order throughput custom metric | ✅ R | CloudWatch log metric filter |
| X-Ray distributed tracing | ✅ D | `k8s/xray/`, SDK in all services |
| All infra via Terraform | ✅ M | `infra/` — 12 modules |
| Remote state + locking (S3 + DynamoDB) | ✅ M | `infra/bootstrap/` |
| Tags (Project, Environment, Team, Owner) | ✅ M | Terraform `default_tags` |
| Cost dashboard + budget alert | ✅ M | `infra/modules/budgets/` |
| Unit economics (cost per 1 000 orders) | ✅ R | `docs/cost-analysis.md` |
| Committed-use discount analysis | ✅ D | `docs/cost-analysis.md` |
| RTO/RPO targets defined | ✅ M | `docs/disaster-recovery.md` |
| RDS automated backups (7-day) | ✅ M | `infra/modules/rds` |
| Velero Kubernetes backup + restore procedure | ✅ D | `k8s/velero/` |
| Multi-AZ RDS (prod) | ✅ R | `rds_multi_az = true` |
| DNS health-check failover → S3 error page | ✅ D | `infra/modules/route53/` + `infra/modules/s3/` |

---

## Team Members

| Name | Student ID | Primary Responsibilities |
|------|------------|--------------------------|
| Madhura Jayashanka | | Networking, EKS, IAM, CI/CD, Security |

---

## Repository Structure

```
CloudMart-demo/
├── services/               # Five microservice source directories
│   ├── product-service/    # Python/Flask + DynamoDB
│   ├── order-service/      # Node.js/Express + SQS
│   ├── user-service/       # Python/Flask + RDS PostgreSQL
│   ├── notification-service/ # Node.js + SQS consumer + SES
│   └── frontend/           # React SPA + Nginx
├── infra/                  # Terraform infrastructure as code
│   ├── bootstrap/          # S3 state bucket + DynamoDB lock table
│   ├── environments/       # prod/ and staging/ environment configs
│   └── modules/            # 14 reusable modules
├── k8s/                    # Kubernetes manifests
│   ├── base/               # Kustomize base resources
│   ├── overlays/           # prod/ and staging/ Kustomize overlays
│   ├── helm/               # Helm charts (umbrella + per service)
│   ├── argocd/             # GitOps ArgoCD applications
│   ├── keda/               # KEDA ScaledObjects
│   ├── velero/             # Backup schedule and restore procedure
│   ├── xray/               # X-Ray daemon DaemonSet
│   └── security/           # Kyverno ClusterPolicies
├── .github/workflows/      # GitHub Actions CI/CD
├── docs/                   # ADRs, cost analysis, DR plan
└── docker-compose.yml      # Local development
```

---

## Quick Start — Local Development

```bash
# Clone and start all services locally
git clone https://github.com/madhurajayashanka/CloudMart-demo.git
cd CloudMart-demo
docker-compose up --build

# Services available at:
# Frontend:           http://localhost:3000
# Product Service:    http://localhost:8001
# Order Service:      http://localhost:8002
# User Service:       http://localhost:8003
```

---

## Deployment Guide — AWS EKS

### Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform ≥ 1.6
- kubectl, helm, argocd CLI
- Domain registered in Route 53 (optional — ALB DNS works without it)

### Step 1: Bootstrap Terraform State

```bash
cd infra/bootstrap
terraform init
terraform apply -var="account_id=$(aws sts get-caller-identity --query Account --output text)"
```

### Step 2: Deploy Infrastructure (Staging first)

```bash
cd infra/environments/staging
# Edit terraform.tfvars — set alert_email, ses_from_email (optional)
terraform init -backend-config=backend.tf
terraform plan -out=tfplan
terraform apply tfplan
```

### Step 3: Configure kubectl

```bash
aws eks update-kubeconfig \
  --name cloudmart-staging \
  --region us-east-1
kubectl get nodes
```

### Step 4: Install Cluster Add-ons

```bash
# AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=cloudmart-staging \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform -chdir=infra/environments/staging output -raw lb_controller_role) \
  -f k8s/helm-values/aws-load-balancer-controller.yaml

# Metrics Server
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm install metrics-server metrics-server/metrics-server -n kube-system \
  -f k8s/helm-values/metrics-server.yaml

# External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  -f k8s/helm-values/external-secrets.yaml

# KEDA
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda -n keda --create-namespace \
  -f k8s/helm-values/keda.yaml

# Kyverno
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
  -f k8s/helm-values/kyverno.yaml

# Cluster Autoscaler
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=cloudmart-staging \
  -f k8s/helm-values/cluster-autoscaler.yaml

# Argo Rollouts
helm repo add argo https://argoproj.github.io/argo-helm
helm install argo-rollouts argo/argo-rollouts \
  -n argo-rollouts --create-namespace \
  -f k8s/helm-values/argo-rollouts.yaml

# Velero
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm install velero vmware-tanzu/velero \
  -n velero --create-namespace \
  -f k8s/velero/velero-values.yaml
```

### Step 5: Apply Kubernetes Manifests

```bash
# Update ACCOUNT_ID placeholders
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
find k8s/ -type f -name "*.yaml" -exec sed -i "s/ACCOUNT_ID/$ACCOUNT_ID/g" {} +

# Apply Kyverno policies
kubectl apply -f k8s/security/

# Apply X-Ray daemon
kubectl apply -f k8s/xray/

# Apply KEDA ScaledObject
kubectl apply -f k8s/keda/notification-service-scaledobject-staging.yaml

# Apply application manifests via Kustomize
kubectl apply -k k8s/overlays/staging

# Apply Velero backup schedule
kubectl apply -f k8s/velero/backup-schedule.yaml
```

### Step 6: Push Images to ECR (first time)

```bash
# Run CI pipeline or push manually
aws ecr get-login-password --region us-east-1 | docker login \
  --username AWS \
  --password-stdin $ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com

for SERVICE in product-service order-service user-service notification-service frontend; do
  docker build -t $ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/cloudmart/$SERVICE:latest \
    services/$SERVICE/
  docker push $ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/cloudmart/$SERVICE:latest
done
```

### Step 7: Set up GitHub Actions Secrets

In GitHub repository Settings → Secrets:

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | `terraform output -raw github_actions_role` |
| `ARGOCD_PASSWORD` | ArgoCD admin password (see `k8s/argocd/install/README.md`) |

### Step 8: Deploy Production

```bash
cd infra/environments/prod
terraform init -backend-config=backend.tf
terraform apply
```

Then push to `main` branch — the CD pipeline will prompt for approval before deploying.

---

## Running Tests

```bash
# Python services
pip install pytest flask bcrypt pyjwt
pytest services/product-service/tests/ -v
pytest services/user-service/tests/ -v

# Node.js services
npm ci --prefix services/order-service
npm test --prefix services/order-service

# Lint Python
flake8 services/product-service services/user-service --max-line-length=120
```

---

## Demo Script

Follow the demo checkpoints in `guideline.md §7`:

```bash
# 1. Infrastructure
kubectl get nodes
kubectl get pods -n cloudmart-prod

# 2. Networking — confirm RDS not internet-accessible
nc -zv <rds-endpoint> 5432  # from external host — should fail
kubectl get networkpolicy -n cloudmart-prod

# 3. Security
kubectl get networkpolicy -n cloudmart-prod
kubectl describe sa product-service-sa -n cloudmart-prod

# 4. Autoscaling demo
kubectl run load-test --image=busybox --restart=Never -- \
  sh -c "while true; do wget -q -O- http://product-service:8001/products; done" \
  -n cloudmart-prod
kubectl get hpa -n cloudmart-prod -w

# 5. Observability
kubectl logs -l app=product-service -n cloudmart-prod --tail=50

# 6. Disaster Recovery — demo Velero restore
velero backup get
velero restore create --from-backup <backup-name> \
  --namespace-mappings cloudmart-prod:cloudmart-restore-test --wait
kubectl get pods -n cloudmart-restore-test
```

---

## Architecture Decision Records

| ADR | Decision | Status |
|-----|----------|--------|
| [ADR-001](docs/adr/ADR-001-node-instance-type.md) | EKS node: t3.medium | Accepted |
| [ADR-002](docs/adr/ADR-002-database-user-service.md) | RDS PostgreSQL for user-service | Accepted |
| [ADR-003](docs/adr/ADR-003-product-service-deployment.md) | Canary deployment via Argo Rollouts | Accepted |

---

## Cost Breakdown (estimated monthly, prod)

| Resource | Spec | Est. Cost |
|----------|------|-----------|
| EKS Cluster | Control plane | $72 |
| EC2 Nodes | 2× t3.medium (on-demand) | $61 |
| RDS PostgreSQL | db.t3.small, Multi-AZ | $55 |
| DynamoDB | On-demand (< 1M requests) | $2 |
| SQS | < 1M messages | $0 (free tier) |
| NAT Gateways | 2× (HA) | $65 |
| ALB | 1× | $18 |
| S3 / ECR / Misc | | ~$5 |
| **Total** | | **~$278/month** |

**Unit economics:** At 10 000 orders/month → **$0.028 per order** (see `docs/cost-analysis.md`).

**1-year Reserved Instance saving:** Switching to t3.medium 1-year RI (~$0.0278/hr) saves ~40% → **~$26/month** per node = **~$52/month** total.
