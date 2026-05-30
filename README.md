# CloudMart — Production-Grade Microservices Platform on AWS EKS

CloudMart is a production-grade e-commerce platform built as five microservices on
**Amazon EKS**. This repository contains the complete application source, container
images, Kubernetes manifests, Terraform infrastructure, and CI/CD pipelines for the
platform across **staging** and **production** environments.

## Chosen Cloud Provider

**Amazon Web Services (AWS)** — selected for the maturity of its managed Kubernetes
(EKS), first-class IRSA workload identity, and the breadth of managed backends the
services depend on (RDS, DynamoDB, SQS, SES, Secrets Manager, KMS).

| Generic service | AWS service used |
|-----------------|------------------|
| Managed Kubernetes | Amazon EKS |
| Container Registry | Amazon ECR |
| Relational DB | Amazon RDS (PostgreSQL 15) |
| NoSQL DB | Amazon DynamoDB |
| Message Queue | Amazon SQS |
| Email | Amazon SES |
| Load Balancer / Ingress | ALB + AWS Load Balancer Controller |
| Monitoring / Logging | CloudWatch Container Insights + Logs |
| Threat Detection | Amazon GuardDuty |
| WAF | AWS WAF v2 |
| Secrets / Keys | Secrets Manager + KMS |
| Object Storage | Amazon S3 |

## Architecture Summary

- **Network** — `/16` VPC across 2 AZs, three-tier subnets (public, private-app,
  private-data), IGW + NAT gateways, per-tier route tables, security groups scoped by
  least privilege, S3/DynamoDB gateway endpoints, Secrets Manager/ECR interface
  endpoints, and VPC Flow Logs shipped to CloudWatch.
- **Compute** — EKS managed node group (t3.medium, IMDSv2 enforced) with Cluster
  Autoscaler; all five services run 2+ replicas with HPA, PDB, probes, and a rolling
  strategy of `maxSurge:1 / maxUnavailable:0`.
- **Security** — per-service IRSA roles (resource-scoped, no node-level data access),
  default-deny NetworkPolicies with explicit allow rules, KMS encryption at rest, RDS
  TLS enforced in transit (`rds.force_ssl`), Secrets injected via External Secrets
  Operator, Kyverno admission policies, WAF on the ALB, and GuardDuty threat detection.
- **Delivery** — GitHub Actions CI (lint, test, build, Trivy scan, manifest validation)
  and CD (staging on `develop`, production on `main` with a manual approval gate,
  pre-deploy Velero backup, smoke tests, and automatic rollback). Argo Rollouts drives a
  canary for product-service; ArgoCD provides optional GitOps sync.
- **Observability** — CloudWatch dashboards (CPU/memory, request/error rate, queue
  depth, DB connections), per-service log groups, a product-service error-rate alarm, a
  custom order-throughput metric, and X-Ray distributed tracing.
- **DR** — RDS Multi-AZ + 7-day PITR, DynamoDB PITR, Velero namespace backups, and
  Route 53 health-check DNS failover to an S3 maintenance page.

The five services and their communication patterns are described in
[docs/](docs/) and the architecture diagrams (D1–D5) accompanying the written report.

## Repository Structure

```
CloudMart/
├── infra/                  # Terraform IaC
│   ├── bootstrap/          # S3 state bucket + DynamoDB lock table
│   ├── environments/       # prod/ and staging/ environment roots
│   └── modules/            # Reusable modules (vpc, eks, rds, iam, monitoring, …)
├── k8s/                    # Kubernetes manifests (Kustomize base + overlays, Helm charts)
├── services/               # Microservice source code + Dockerfiles
├── docs/                   # ADRs, cost analysis, disaster-recovery plan
├── .github/workflows/      # CI / CD pipelines
└── docker-compose.yml      # Local development environment
```

## Prerequisites

- AWS account with permissions to create the resources above
- Terraform ≥ 1.6, AWS CLI v2, kubectl, kustomize, Helm 3, Docker
- A GitHub repo with the OIDC role + secrets configured (`AWS_ROLE_ARN`, etc.)

## Deployment Instructions

### 1. Bootstrap remote state

```bash
cd infra/bootstrap
terraform init && terraform apply      # creates S3 state bucket + DynamoDB lock table
```

### 2. Provision infrastructure (per environment)

```bash
cd infra/environments/prod              # or environments/staging
terraform init -backend-config=backend.tf
terraform plan  -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

Before applying, set in `terraform.tfvars`:
- `alert_email`, `ses_from_email`
- `bastion_allowed_cidrs` — your admin/VPN IP (leave `[]` to use SSM Session Manager)
- (optional) `domain_name` for Route 53 DNS failover

### 3. Configure kubectl and platform add-ons

```bash
aws eks update-kubeconfig --name cloudmart-prod --region us-east-1
# Install controllers referenced by k8s/helm-values/ (LB controller, external-secrets,
# metrics-server, cluster-autoscaler, kyverno, keda, argo-rollouts, argocd) via Helm.
```

### 4. Deploy the application

```bash
# GitOps (preferred): push to develop -> staging, main -> production
# or apply directly:
kubectl apply -k k8s/overlays/prod
kubectl get pods -n cloudmart-prod
```

CI/CD then handles builds and deploys automatically: pushes to `develop` deploy to
`cloudmart-staging`; pushes to `main` deploy to `cloudmart-prod` after manual approval.

### Local development

```bash
docker compose up --build      # runs all five services with in-memory backends
```

## Team Members & Contributions

| Member | Role | Primary Contributions |
|--------|------|-----------------------|
| Madhura Jayashanka | Platform / DevOps | Environment roots (prod/staging), CI/CD pipelines, monitoring & alarms, budgets, Velero/DR, cost & DR documentation |
| Dilshan Prasanna Allepola | Core Infrastructure | Terraform networking (VPC) and managed-data modules — RDS, DynamoDB, SQS, S3, KMS, Route 53 |
| Asela Maduwantha | Kubernetes & GitOps | K8s base manifests, NetworkPolicies, Kustomize overlays, external-secrets, ArgoCD, Kyverno policies, EKS/ECR |
| Akhila Sanjeewa | Application & Helm | Microservice source (product/order/user/notification), Helm charts and values files |
| Himasha Kodikara | Security & Frontend | IAM/IRSA workload identity, secrets integration, frontend SPA and cross-service app wiring |

## Further Documentation

- [Architecture Decision Records](docs/adr/) — node type, user-service DB, deployment strategy
- [Cost Analysis & FinOps](docs/cost-analysis.md)
- [Disaster Recovery Plan](docs/disaster-recovery.md)
