# CloudMart — End-to-End Instructions

> **Cloud Provider:** AWS  
> **Region:** `us-east-1` (default; parameterized via `AWS_REGION` / `TF_VAR_aws_region` — nothing hardcoded)  
> **Kubernetes:** Amazon EKS (v1.30)  
> **Team:** group-01  
> **Branch strategy:** `main` → production, `develop` → staging, `feature/*` → development

---

## Table of Contents

1. [Prerequisites — What You Need Installed](#1-prerequisites)
2. [Phase 1 — Local Development & Testing](#2-local-development)
3. [Phase 2 — AWS Credential Configuration](#3-aws-credentials)
4. [Phase 3 — One-Command Cloud Deployment](#4-cloud-deployment)
5. [Phase 4 — GitHub Actions CI/CD Setup](#5-github-cicd)
6. [Phase 5 — Pushing Changes Through the Pipeline](#6-pushing-changes)
7. [Phase 6 — Viva Demo Verification Commands](#7-viva-demo)
8. [Phase 7 — One-Command Destruction](#8-destruction)
9. [Phase 8 — Post-Destroy Verification](#9-verification)
10. [Cost Estimate — 1 Week of Staging](#10-cost)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Prerequisites

Install these tools on your machine before proceeding.

| Tool | Version | Install Command (macOS) |
|---|---|---|
| AWS CLI v2 | ≥ 2.15 | `brew install awscli` |
| Terraform | ≥ 1.6 | `brew install terraform` |
| kubectl | ≥ 1.29 | `brew install kubectl` |
| Helm | ≥ 3.14 | `brew install helm` |
| Docker Desktop | latest | [Download](https://www.docker.com/products/docker-desktop/) |
| Git | ≥ 2.40 | `brew install git` |

> **Verify installations:**
> ```bash
> aws --version && terraform --version && kubectl version --client && helm version && docker --version && git --version
> ```

---

## 2. Local Development

Test the full microservices stack locally using Docker Compose before touching AWS.

### 2.1 Start the Application

```bash
cd ~/Desktop/CloudMart-demo
docker compose up --build
```

### 2.2 Access the Services

| Service | URL | Expected |
|---|---|---|
| Frontend (React SPA) | http://localhost:3000 | CloudMart UI loads |
| Product Service | http://localhost:8001/health | `{"status":"ok"}` |
| Order Service | http://localhost:8002/health | `{"status":"ok"}` |
| User Service | http://localhost:8003/health | `{"status":"ok"}` |
| Notification Service | http://localhost:8004/health | `{"status":"ok"}` |

### 2.3 End-to-End Local Walkthrough

1. Open http://localhost:3000
2. **Register** a new user → Sign in
3. **Browse** products → **Add to cart** → **Checkout**
4. Watch the `cloudmart-notification` container logs — you will see `[CONSOLE] Email sent` confirming the notification-service consumed the SQS event and processed it

### 2.4 Run Unit Tests

```bash
# Python services (product-service, user-service)
pip install pytest flask bcrypt pyjwt
pytest services/product-service/tests/ -v
pytest services/user-service/tests/ -v

# Node.js services (order-service)
npm ci --prefix services/order-service
npm test --prefix services/order-service
```

### 2.5 Stop Local Stack

```bash
docker compose down -v
```

---

## 3. AWS Credentials

### 3.1 Configure the CLI

```bash
aws configure
```

Enter when prompted:
- **Access Key ID:** your IAM access key
- **Secret Access Key:** your IAM secret key
- **Default region:** `us-east-1`
- **Output format:** `json`

### 3.2 Verify Authentication

```bash
aws sts get-caller-identity
```

> [!IMPORTANT]
> The IAM user/role **must have `AdministratorAccess`** policy attached. Terraform creates 20+ resource types (EKS, RDS, VPC, IAM roles, WAF, GuardDuty, KMS, SQS, DynamoDB, S3, ECR, CloudTrail, CloudWatch, SNS, Budgets, etc.) and needs broad permissions.

### 3.3 Ensure Docker Desktop Is Running

The deployment script will build 5 Docker images and push them to ECR. Docker must be running:

```bash
docker info   # Should print "Server: Docker Desktop" — not an error
```

---

## 4. One-Command Cloud Deployment

### 4.1 Deploy Staging

```bash
cd ~/Desktop/CloudMart-demo
./deploy.sh -e staging
```

**This single command performs ALL of the following automatically:**

| Step | What It Does | Approx Time |
|---|---|---|
| 1 | Detects your AWS Account ID | instant |
| 2 | Replaces `ACCOUNT_ID` placeholders in all K8s YAML files | instant |
| 3 | `terraform init` + `apply` in `infra/bootstrap/` — creates S3 state bucket + DynamoDB lock table | 30s |
| 4 | `terraform init` + `apply` in `infra/environments/staging/` — creates VPC, EKS, RDS, DynamoDB, SQS, ECR, KMS, WAF, GuardDuty, CloudTrail, IAM roles, budgets | **12–18 min** |
| 5 | Patches Ingress for HTTP-only (no domain needed) | instant |
| 6 | Injects real IAM role ARNs into Helm value files and K8s manifests | instant |
| 7 | `aws eks update-kubeconfig` — connects kubectl | 5s |
| 8 | Installs 7 Helm charts: AWS LB Controller, Metrics Server, External Secrets, KEDA, Kyverno, Cluster Autoscaler, Velero | 3–5 min |
| 9 | Applies Kyverno policies, X-Ray DaemonSet, KEDA ScaledObject, Kustomize overlay | 30s |
| 10 | Builds 5 Docker images and pushes to ECR | 3–5 min |
| 11 | Rolling restart of all deployments | 30s |

**Total: ~20–30 minutes (mostly EKS provisioning)**

### 4.2 Verify the Deployment

After the script finishes, wait ~2 minutes for the ALB to provision:

```bash
# Get the ALB URL
kubectl get ingress cloudmart-ingress -n cloudmart-staging

# Once ADDRESS column shows a hostname, open it in your browser:
# http://k8s-cloudmar-xxxxxxxx-xxxxxxxxx.us-east-1.elb.amazonaws.com
```

### 4.3 What the Script Prints at the End

The deploy script prints the **GitHub Actions Role ARN** that you need for the next phase. Copy it — you will paste it into GitHub Secrets.

```
[INFO]   GitHub Actions Role ARN (set as AWS_ROLE_ARN secret):
[INFO]     arn:aws:iam::123456789012:role/cloudmart-github-actions-role-staging
```

---

## 5. GitHub Actions CI/CD Setup

This one-time setup enables automatic deployments on every `git push`.

### 5.1 Create a GitHub Repository

1. Go to https://github.com/new
2. Create a **private** repository (e.g., `CloudMart-demo`)
3. Do **NOT** add a README (you already have one)

### 5.2 Configure the GitHub OIDC Trust

The Terraform IAM module has already created an OIDC provider for GitHub Actions and an IAM role scoped to your repository.

> [!IMPORTANT]
> The IAM module defaults to `github_org = "asela-maduwantha"` and `github_repo = "CloudMart-demo"`. If your GitHub username or repo name differs, update these values in `infra/modules/iam/variables.tf` **before** running deploy.sh, or re-run `terraform apply` after updating.

### 5.3 Add Repository Secrets

1. Go to your GitHub repo → **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository secret**
3. Add:
   - **Name:** `AWS_ROLE_ARN`
   - **Value:** the role ARN printed by `deploy.sh` (from step 4.3)

### 5.4 Create GitHub Environments

1. Go to **Settings** → **Environments**
2. Create environment named `staging` (no protection rules needed)
3. Create environment named `production` → enable **Required reviewers** → add yourself

### 5.5 Push Code to GitHub

```bash
cd ~/Desktop/CloudMart-demo
git init
git remote add origin https://github.com/YOUR_USERNAME/CloudMart-demo.git
git checkout -b develop
git add .
git commit -m "feat: initial cloudmart infrastructure and services"
git push -u origin develop
```

This push triggers the **CI pipeline** (`ci.yml`) which:
- Runs Python linting + unit tests for product-service & user-service
- Runs Node.js unit tests for order-service & notification-service
- Builds all 5 Docker images
- Scans each with Trivy (fails on CRITICAL vulnerabilities)
- Pushes images to ECR tagged with the commit SHA
- Validates Kubernetes manifests with kubeconform

Then the **CD staging pipeline** (`cd-staging.yml`) triggers automatically and:
- Updates kubeconfig for the staging EKS cluster
- Substitutes `ACCOUNT_ID` in manifests (in the runner, not in your repo)
- Sets image tags to the commit SHA via `kustomize edit set image`
- Applies the staging overlay to the cluster
- Waits for all deployments to roll out
- Runs smoke tests (pod readiness + HTTP checks against the ALB)

---

## 6. Pushing Changes Through the Pipeline

After the initial setup, the workflow for every code change is:

### Staging (automatic)

```bash
# Make a change (e.g., edit frontend text, fix a bug)
git checkout develop
# ... edit files ...
git add .
git commit -m "fix: update product card layout"
git push origin develop
```

→ CI runs → CD deploys to staging → change is live on the staging ALB URL within ~5 minutes

### Production (manual approval)

```bash
# Merge develop into main
git checkout main
git merge develop
git push origin main
```

→ CI runs → **Manual approval gate** in GitHub (you click "Approve") → Velero backup snapshot → CD deploys to production → health-gated rolling update for all services

---

## 7. Viva Demo Verification Commands

Use these during the live demo to demonstrate each assessment checkpoint.

### Checkpoint 1 — Infrastructure

```bash
kubectl get nodes                              # Show 2+ worker nodes
kubectl get pods -n cloudmart-staging -o wide   # All pods Running/Ready
```

### Checkpoint 2 — End-to-End Flow

Open the ALB URL in the browser. Register → login → browse products → place order → check notification logs:

```bash
kubectl logs -l app=notification-service -n cloudmart-staging --tail=20
```

### Checkpoint 3 — Database Isolation

```bash
# Get the RDS endpoint
cd infra/environments/staging
RDS_HOST=$(terraform output -raw rds_endpoint | cut -d: -f1)
cd ../../..

# Prove it's unreachable from the public internet
nc -zv $RDS_HOST 5432      # Will timeout — database is in private-data subnet
```

### Checkpoint 4 — Security

```bash
kubectl get networkpolicy -n cloudmart-staging   # Default-deny + explicit allows
kubectl get clusterpolicy                         # Kyverno: block-root, ecr-only, require-limits
kubectl describe sa product-service-sa -n cloudmart-staging  # Shows IRSA role ARN
```

### Checkpoint 5 — CI/CD

Make a small text change in the frontend, push to `develop`, and show the pipeline running in GitHub Actions. Then show the updated text on the staging URL.

### Checkpoint 6 — Autoscaling

```bash
kubectl get hpa -n cloudmart-staging             # HPA targets 60% CPU
kubectl get scaledobject -n cloudmart-staging     # KEDA scales notification-service on SQS depth
```

### Checkpoint 7 — Observability

Open the **AWS CloudWatch** console:
- **Container Insights** → show CPU/memory per pod
- **Log groups** → `/cloudmart/` → show application logs
- **X-Ray** → show distributed traces

### Checkpoint 8 — Cost Management

Open the **AWS Billing** console:
- **Cost Explorer** → filter by tag `Project=cloudmart` → show daily spend
- **Budgets** → show the $30/month budget alert

### Checkpoint 9 — Disaster Recovery

```bash
# Show RDS automated backups
aws rds describe-db-instances \
  --query 'DBInstances[0].{BackupRetention:BackupRetentionPeriod,MultiAZ:MultiAZ}' \
  --output table

# Show Velero backup schedule
kubectl get schedule -n velero
velero backup get 2>/dev/null || echo "Velero schedules configured in k8s/velero/"
```

---

## 8. One-Command Destruction

> [!CAUTION]
> This destroys **ALL** CloudMart AWS resources permanently. Run this only when you are done with the viva and no longer need the infrastructure.

```bash
cd ~/Desktop/CloudMart-demo
./destroy.sh -e staging
```

**The script performs the following in strict order:**

| Step | What It Does | Why This Order Matters |
|---|---|---|
| 1 | Delete Kubernetes Ingress | Releases the ALB, target groups, and ENIs attached to VPC subnets |
| 2 | Wait 120 seconds | ALB controller needs time to fully de-provision AWS resources |
| 3 | Delete application namespace | Cascades deletion of all pods, services, PVCs |
| 4 | Uninstall 8 Helm releases | Removes controllers that manage AWS resources (LB controller, etc.) |
| 5 | Delete CRDs | Kyverno/KEDA CRDs can block node group deletion |
| 6 | `terraform destroy` (environment) | Destroys EKS, VPC, RDS, DynamoDB, SQS, KMS, WAF, GuardDuty, CloudTrail, IAM, etc. |
| 7 | Empty + delete S3 buckets | S3 buckets with content cannot be deleted — script handles versioned objects too |
| 8 | `terraform destroy` (bootstrap) | Destroys the state S3 bucket and DynamoDB lock table |
| 9 | Delete CloudWatch log groups | Prevents log storage charges |
| 10 | Release Elastic IPs | Prevents charges for unassociated EIPs left by NAT gateway |
| 11 | Automated verification | Checks EKS, ALB, NAT, RDS, ECR, S3, DynamoDB for zero remaining resources |

**Total destruction time: ~15–20 minutes**

---

## 9. Post-Destroy Verification

The destroy script prints an automated checklist at the end:

```
  ✓ EKS Clusters
  ✓ Load Balancers
  ✓ NAT Gateways
  ✓ RDS Instances
  ✓ ECR Repositories
  ✓ S3 Buckets
  ✓ DynamoDB Tables
```

**If any line shows ✗, manually delete the resource:**

```bash
# Example: delete a lingering load balancer
aws elbv2 delete-load-balancer --load-balancer-arn <arn>

# Example: delete a lingering NAT gateway
aws ec2 delete-nat-gateway --nat-gateway-id <id>
# Then release its Elastic IP
aws ec2 release-address --allocation-id <eip-alloc-id>

# Example: force-delete an ECR repository
aws ecr delete-repository --repository-name cloudmart/product-service --force
```

**Final manual check — open the AWS Console:**
- **Billing Dashboard** → verify no new charges accumulating
- **EC2 → Elastic IPs** → verify none allocated
- **VPC** → verify the `cloudmart-*` VPC is deleted

---

## 10. Cost Estimate — 1 Week of Staging

All cost-saving measures are pre-configured in `infra/environments/staging/terraform.tfvars`:
- `single_nat_gateway = true` (1 NAT instead of 2)
- `rds_multi_az = false` (single-AZ database)
- `db_instance_class = "db.t3.micro"` (smallest instance)
- `eks_min_nodes = 2` (minimum viable cluster)

| Resource | Rate | 1 Week (168 hrs) |
|---|---|---:|
| EKS Control Plane | $0.10/hr | $16.80 |
| EC2 Workers (2× m7i-flex.large) | $0.09576/hr × 2 | $32.18 |
| NAT Gateway | $0.045/hr | $7.56 |
| VPC Endpoints (3 Interface × 2 AZ) | $0.01/hr × 6 | $10.08 |
| ALB | $0.0225/hr + LCU | ~$3.78 |
| RDS PostgreSQL (db.t3.micro) | $0.017/hr | $2.86 |
| Storage, data transfer, logs | variable | ~$2.00 |
| **Total** | | **~$75** |

> [!TIP]
> If you want to save more during nights/weekends when you're not testing, you can scale the node group to 0 and back:
> ```bash
> # Scale down (stop billing for EC2 workers)
> aws eks update-nodegroup-config --cluster-name cloudmart-staging \
>   --nodegroup-name cloudmart-nodes-staging \
>   --scaling-config minSize=0,maxSize=4,desiredSize=0
>
> # Scale back up
> aws eks update-nodegroup-config --cluster-name cloudmart-staging \
>   --nodegroup-name cloudmart-nodes-staging \
>   --scaling-config minSize=2,maxSize=4,desiredSize=2
> ```
> This saves the EC2 cost ($14/week) but keeps the EKS control plane running ($16.80/week). Pods will reschedule automatically when nodes come back.

---

## 11. Troubleshooting

### "Terraform destroy fails on VPC — subnets still in use"

This happens when ALB ENIs were not cleaned up before Terraform tried to delete subnets. Fix:

```bash
# Find and delete lingering ENIs
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$(aws ec2 describe-vpcs --filters 'Name=tag:Name,Values=cloudmart-*' --query 'Vpcs[0].VpcId' --output text)" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text \
  | xargs -n1 aws ec2 delete-network-interface --network-interface-id

# Then re-run
terraform destroy -auto-approve
```

### "Pods stuck in ImagePullBackOff"

ECR images haven't been pushed yet or the node role can't pull:

```bash
# Verify images exist
aws ecr list-images --repository-name cloudmart/product-service

# If empty, push manually
./deploy.sh -e staging   # Re-run is idempotent
```

### "ALB not provisioning (no ADDRESS in ingress)"

The AWS Load Balancer Controller may not be healthy:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=30
```

### "GuardDuty detector already exists"

If you re-deploy without fully destroying, GuardDuty may conflict:

```bash
# Manually delete the existing detector
DETECTOR_ID=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)
aws guardduty delete-detector --detector-id $DETECTOR_ID
```

### "S3 bucket already exists"

If a previous destroy partially failed:

```bash
aws s3 rm s3://cloudmart-tf-state-<ACCOUNT_ID> --recursive
aws s3api delete-bucket --bucket cloudmart-tf-state-<ACCOUNT_ID>
```
