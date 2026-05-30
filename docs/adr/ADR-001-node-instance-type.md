# ADR-001: EKS Node Instance Type Selection

**Date:** 2025-01-15
**Status:** Accepted
**Deciders:** CloudMart Platform Team

---

## Context

CloudMart runs 5 microservices on Amazon EKS. We need to choose an EC2 instance type for the managed node group that:
- Comfortably fits all 5 service pods plus system pods (CoreDNS, kube-proxy, vpc-cni, CloudWatch agent)
- Stays within a student-project budget
- Provides enough headroom for Cluster Autoscaler to add nodes under load

The total resource requests across all 5 services on a single node are approximately:
- CPU: ~400m requests / ~1900m limits
- Memory: ~512Mi requests / ~1024Mi limits

Nodes must also host the EKS system pods (≈ 200m CPU, 300Mi memory overhead).

## Considered Options

| Option | vCPU | RAM | On-Demand Price (us-east-1) | Notes |
|--------|------|-----|--------------------------|-------|
| t3.small | 2 | 2 GB | ~$0.021/hr (~$15/month) | Too small — insufficient memory for 5 services + system |
| **t3.medium** | **2** | **4 GB** | **~$0.042/hr (~$30/month)** | **Fits 2+ service pods comfortably** |
| t3.large | 2 | 8 GB | ~$0.083/hr (~$60/month) | Overkill for development; unnecessary cost |
| m5.large | 2 | 8 GB | ~$0.096/hr (~$69/month) | Better CPU but expensive for a student budget |

## Decision

**Use t3.medium** for both staging and production node groups.

Rationale:
- 4 GB RAM is sufficient to run all service pods (actual usage ~600–800 Mi at rest) with headroom for a JVM burst or memory spike
- t3 instances include burstable CPU credits — acceptable for a demo workload with occasional spikes
- At 2 nodes (minimum), cost is ~$60/month, within the $50–80 student budget when combined with other optimisations (single NAT GW in staging, PAY_PER_REQUEST DynamoDB, db.t3.micro RDS)
- Cluster Autoscaler can add nodes in ~3 minutes if pods cannot be scheduled

## Consequences

**Positive:**
- Keeps monthly EC2 cost to ~$60 for 2 nodes
- All 5 services fit comfortably on a single t3.medium for local cluster testing
- Upgrade path to t3.large or m5.large is a Terraform `node_instance_type` variable change

**Negative:**
- CPU bursting: t3.medium accumulates CPU credits and throttles if credits are depleted. Under sustained load (e.g., load test), performance can degrade. Mitigated by HPA auto-scaling and Cluster Autoscaler adding nodes before credits run out.
- Not suitable for memory-intensive workloads (e.g., ML inference). Not a concern for CloudMart.

## Implementation Notes

The instance type is set in `infra/modules/eks/variables.tf`:
```hcl
variable "node_instance_type" { default = "t3.medium" }
```

Staging uses 2–4 nodes; Prod uses 2–6 nodes, controlled by `eks_min_nodes` / `eks_max_nodes` in `terraform.tfvars`.
