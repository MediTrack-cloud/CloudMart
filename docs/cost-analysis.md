# CloudMart Cost Analysis & FinOps

## 1. Monthly Cost Estimate (Production)

All costs are us-east-1 on-demand pricing as of May 2026.

| Resource | Configuration | Unit Price | Qty | Monthly |
|----------|--------------|------------|-----|---------|
| EKS Control Plane | Managed | $0.10/hr | 1 | $73 |
| EC2 (m7i-flex.large) | 2 vCPU / 8 GiB, on-demand | $0.09576/hr | 2 nodes | $140 |
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
| **Total (prod)** | | | | **~$401/month** |

> Node type is m7i-flex.large per ADR-001 — chosen for its 8 GiB (1:4 vCPU:RAM) headroom and latest-gen
> price/performance over the cheaper-but-tighter t3.medium. The ~$80/mo compute premium vs t3.medium is the
> single largest cost-vs-reliability trade-off in this build and is the subject of ADR-001 and §4 below.

## 2. Staging Cost Estimate

| Change from Prod | Saving |
|-----------------|--------|
| Single NAT Gateway | –$33 |
| 1 node (m7i-flex.large) instead of 2 | –$70 |
| RDS db.t3.micro, Single-AZ | –$30 |
| 2 VPC Interface endpoints instead of 4 | –$15 |
| **Total (staging)** | **~$253/month** |

---

## 3. Unit Economics — Cost Per 1 000 Orders

**Assumptions:**
- Production monthly cost: $401
- System capacity: 10 000 orders/month (based on current node sizing)
- All costs attributed to order processing (conservative — includes idle capacity)

```
Cost per order = $401 / 10,000 = $0.0401

Cost per 1,000 orders = $40.10
```

**Infrastructure cost breakdown per 1 000 orders:**

| Layer | Cost | % |
|-------|------|---|
| Compute (EKS + EC2) | $21.30 | 53% |
| Database (RDS + DynamoDB) | $5.70 | 14% |
| Network (NAT + ALB) | $8.30 | 21% |
| Other (WAF, Secrets, KMS, logs, endpoints) | $4.80 | 12% |
| **Total** | **$40.10** | 100% |

**Scale efficiency:** At 50 000 orders/month (5× scale), fixed costs dominate → ~$8.02/1K orders (5× improvement).

---

## 4. Committed Use Discount Analysis (1-Year Commitment)

**Current: On-Demand m7i-flex.large**
- Rate: $0.09576/hr
- 2 nodes × 730 hrs/month = $139.81/month
- Annual: **$1,677.70**

**Option A: 1-Year Reserved (No Upfront)**
- Effective rate: ~$0.0603/hr (~37% saving)
- 2 nodes × 730 hrs = $88.08/month
- Annual: **$1,056.95**
- **Saving: $620.75/year (37%)**

**Option B: 1-Year Reserved (All Upfront)**
- Effective rate: ~$0.0565/hr (~41% saving)
- Annual total: **~$989.84** (paid upfront)
- **Saving: $687.86/year (41%)**

**Option C: Savings Plans (Compute, 1-year)**
- ~30% saving vs on-demand
- More flexible — covers any instance family/region change, and is the **natively recommended commitment vehicle
  for flex instance types** like m7i-flex
- Annual cost: **$1,174.39** → saving **~$503.31/year**

**Recommendation:** **Option A (1-Year RI, No Upfront)** for predictable savings without capital outlay.
Because the node group runs the **flex** instance family, a **Compute Savings Plan (Option C)** is the more
natural long-term fit and is preferred if we expect to change instance family/size — slightly less saving for
materially more flexibility.

| Option | Annual Cost | Saving | Flexibility |
|--------|------------|--------|-------------|
| On-Demand (current) | $1,677.70 | — | Full |
| 1-Year RI No Upfront | $1,056.95 | $621/yr | Medium |
| 1-Year RI All Upfront | $989.84 | $688/yr | Low |
| Savings Plans | $1,174.39 | $503/yr | High |

---

## 5. Cost Optimization Actions Taken

1. **Single NAT Gateway in staging** — saves $33/month vs. HA pair
2. **DynamoDB on-demand billing** — no provisioned capacity cost for variable traffic
3. **ECR lifecycle policies** — retain only 10 images; prevents unbounded storage growth
4. **KEDA scale-to-zero** — notification-service scales to 0 replicas when SQS queue is empty
5. **VPC Gateway Endpoints (S3, DynamoDB)** — eliminates NAT data transfer cost for AWS API calls
6. **m7i-flex.large (flex) instances** — latest-gen general-purpose at ~5% under m7i.large; full CPU performance
   for the majority of the time with a credit-based ceiling only under sustained saturation — appropriate for
   variable e-commerce load, with HPA + Cluster Autoscaler absorbing spikes

---

## 6. AWS Compute Optimizer Recommendations (Simulated)

| Resource | Current | Recommendation | Rationale |
|----------|---------|---------------|-----------|
| EKS nodes | m7i-flex.large | Keep m7i-flex.large | Right-sized for current workload per ADR-001; 8 GiB headroom intentional |
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
