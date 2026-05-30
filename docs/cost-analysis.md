# CloudMart Cost Analysis & FinOps

## 1. Monthly Cost Estimate (Production)

All costs are us-east-1 on-demand pricing as of May 2026.

| Resource | Configuration | Unit Price | Qty | Monthly |
|----------|--------------|------------|-----|---------|
| EKS Control Plane | Managed | $0.10/hr | 1 | $72 |
| EC2 (t3.medium) | 2 vCPU / 4 GiB, on-demand | $0.0416/hr | 2 nodes | $61 |
| RDS PostgreSQL | db.t3.small, Multi-AZ, 20 GiB | $0.068/hr | 1 | $55 |
| DynamoDB | On-demand reads/writes (<1M) | $1.25/M writes | ~100K ops | $2 |
| Amazon SQS | Standard queue (<1M messages) | Free tier | — | $0 |
| SES | Sandbox / <62K emails/month | Free tier | — | $0 |
| NAT Gateway | 2× for HA in prod | $0.045/hr + data | 2 | $65 |
| ALB | Application Load Balancer | $0.008/LCU/hr | 1 | $18 |
| ECR | 5 repos, image storage | $0.10/GB/month | 5 GB | $1 |
| S3 (state + assets) | Standard | $0.023/GB | 10 GB | $1 |
| KMS | 2 CMKs | $1/key/month | 2 | $2 |
| Secrets Manager | 2 secrets | $0.40/secret/month | 2 | $1 |
| GuardDuty | 30-day free trial, then ~$2 | | | $2 |
| CloudWatch | Logs + metrics + dashboard | | | $5 |
| WAF v2 | 5 rules + web ACL | $1/rule/month | 5 | $7 |
| VPC Endpoints | 4 Interface endpoints | $0.01/hr | 4 | $29 |
| **Total (prod)** | | | | **~$321/month** |

## 2. Staging Cost Estimate

| Change from Prod | Saving |
|-----------------|--------|
| Single NAT Gateway | –$33 |
| 1 node (t3.medium) instead of 2 | –$31 |
| RDS db.t3.micro, Single-AZ | –$30 |
| 2 VPC Interface endpoints instead of 4 | –$15 |
| **Total (staging)** | **~$212/month** |

---

## 3. Unit Economics — Cost Per 1 000 Orders

**Assumptions:**
- Production monthly cost: $321
- System capacity: 10 000 orders/month (based on current node sizing)
- All costs attributed to order processing (conservative — includes idle capacity)

```
Cost per order = $321 / 10,000 = $0.0321

Cost per 1,000 orders = $32.10
```

**Infrastructure cost breakdown per 1 000 orders:**

| Layer | Cost | % |
|-------|------|---|
| Compute (EKS + EC2) | $14.70 | 46% |
| Database (RDS + DynamoDB) | $6.30 | 20% |
| Network (NAT + ALB) | $7.60 | 24% |
| Other (WAF, Secrets, logs) | $3.50 | 11% |
| **Total** | **$32.10** | 100% |

**Scale efficiency:** At 50 000 orders/month (5× scale), fixed costs dominate → ~$6.42/1K orders (5× improvement).

---

## 4. Committed Use Discount Analysis (1-Year Reserved Instances)

**Current: On-Demand t3.medium**
- Rate: $0.0416/hr
- 2 nodes × 730 hrs/month = $60.74/month
- Annual: **$728.88**

**Option A: 1-Year Reserved (No Upfront)**
- Rate: $0.0264/hr (37% saving)
- 2 nodes × 730 hrs = $38.54/month
- Annual: **$462.48**
- **Saving: $266.40/year (37%)**

**Option B: 1-Year Reserved (All Upfront)**
- Upfront: $432 ($216 × 2 nodes)
- Effective hourly: $0.0247/hr
- Annual total: **$432 upfront** (no monthly)
- **Saving: $296.88/year (41%)**

**Option C: Savings Plans (Compute, 1-year)**
- Commit to $0.038/hr of compute spend
- ~30% saving vs on-demand
- More flexible — covers any instance family/region change
- Annual saving: **~$218.64**

**Recommendation:** **Option A (1-Year RI, No Upfront)** for predictable savings without capital outlay. Move to Savings Plans if instance type changes are anticipated.

| Option | Annual Cost | Saving | Flexibility |
|--------|------------|--------|-------------|
| On-Demand (current) | $728.88 | — | Full |
| 1-Year RI No Upfront | $462.48 | $266/yr | Medium |
| 1-Year RI All Upfront | $432.00 | $297/yr | Low |
| Savings Plans | $510.24 | $219/yr | High |

---

## 5. Cost Optimization Actions Taken

1. **Single NAT Gateway in staging** — saves $33/month vs. HA pair
2. **DynamoDB on-demand billing** — no provisioned capacity cost for variable traffic
3. **ECR lifecycle policies** — retain only 10 images; prevents unbounded storage growth
4. **KEDA scale-to-zero** — notification-service scales to 0 replicas when SQS queue is empty
5. **VPC Gateway Endpoints (S3, DynamoDB)** — eliminates NAT data transfer cost for AWS API calls
6. **t3.medium burstable instances** — provides 20% baseline CPU with burst; appropriate for variable e-commerce load

---

## 6. AWS Compute Optimizer Recommendations (Simulated)

| Resource | Current | Recommendation | Rationale |
|----------|---------|---------------|-----------|
| EKS nodes | t3.medium | Keep t3.medium | Right-sized for current workload per ADR-001 |
| RDS (prod) | db.t3.small | Accept — suitable | Consistent < 20% CPU per monitoring |
| RDS (staging) | db.t3.micro | Accept | Test workload, low memory pressure |
| DynamoDB | On-demand | Accept | Variable traffic; provisioned would cost more |

---

## 7. Tagging Strategy

All resources are tagged for cost attribution:

```
Project     = cloudmart
Environment = prod | staging
Team        = group-01
Owner       = madhuraweerasooriye@gmail.com
ManagedBy   = terraform
```

Tags are applied via Terraform `default_tags` in the provider block — no resource escapes untagged.

**Cost allocation:** In AWS Cost Explorer, filter by `Project=cloudmart` to see total spend, or drill down by `Environment` to compare prod vs. staging daily spend.
