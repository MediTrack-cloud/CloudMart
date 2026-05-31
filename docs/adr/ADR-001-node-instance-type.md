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
- Matches the CI build target (images are built `--platform linux/amd64` in `.github/workflows/ci.yml`)

The total resource requests across all 5 services on a single node are approximately:
- CPU: ~400m requests / ~1900m limits
- Memory: ~512Mi requests / ~1024Mi limits

Nodes must also host the EKS system pods (≈ 200m CPU, 300Mi memory overhead). Our services are
comparatively memory-leaning (Node.js + Python runtimes with cloud SDKs), so a **1:4 vCPU:RAM ratio
(8 GiB on 2 vCPU)** gives more useful headroom than a 1:2 ratio for the same vCPU count.

## Considered Options

The brief requires comparing a general-purpose, a compute-optimised, and an ARM-based option.

| Option | Class | vCPU | RAM | vCPU:RAM | On-Demand (us-east-1) | Notes |
|--------|-------|------|-----|----------|----------------------|-------|
| t3.medium | General-purpose (burstable) | 2 | 4 GB | 1:2 | ~$0.0416/hr (~$30/mo) | Cheapest, but 4 GB is tight once system pods + 5 services land on one node; hard CPU-credit ceiling |
| **m7i-flex.large** | **General-purpose (latest-gen Intel, flex)** | **2** | **8 GB** | **1:4** | **~$0.09576/hr (~$70/mo)** | **Chosen — 8 GB headroom, Sapphire Rapids price/perf, flex pricing ~5% under m7i.large** |
| c7i.large | Compute-optimised | 2 | 4 GB | 1:2 | ~$0.08925/hr (~$65/mo) | Strong sustained CPU, but only 4 GB and costs nearly as much as m7i-flex with less RAM |
| m7g.large | ARM (Graviton3) | 2 | 8 GB | 1:4 | ~$0.0816/hr (~$60/mo) | ~15% cheaper than m7i-flex, but **requires arm64 / multi-arch images** |

## Decision

**Use m7i-flex.large** for both staging and production node groups
(`infra/modules/eks/variables.tf`, default `node_instance_type = "m7i-flex.large"`).

Rationale:
- **8 GiB RAM (1:4 ratio)** comfortably fits all 5 service pods + EKS system pods with room for spikes,
  unlike the 4 GiB options (t3.medium / c7i.large), which leave little margin once everything is co-scheduled.
- **Latest-generation Intel (Sapphire Rapids)** gives better price/performance than the t3 (Skylake/Cascade Lake)
  family; the **"flex"** variant is ~5% cheaper than m7i.large and is sized for services that do not pin CPU
  100% of the time — exactly CloudMart's variable e-commerce load. Flex nodes deliver full CPU performance for
  the majority of the time and rely on a credit system only under sustained max load, mitigated by HPA + Cluster Autoscaler.
- **amd64 alignment:** CI builds images as `linux/amd64`. m7i-flex runs amd64 natively with no image changes.

## Consequences

**Positive:**
- 8 GiB headroom removes the memory pressure risk that 4 GiB nodes carry once all services co-locate.
- Newer silicon → better baseline performance per dollar than the t3 family.
- Drop-in for the existing amd64 image pipeline — no multi-arch build work.
- Upgrade/downgrade is a single Terraform `node_instance_type` change.

**Negative:**
- **Higher cost** than t3.medium: ~$70/mo vs ~$30/mo per node (~$140 vs ~$60 for the 2-node minimum).
  Accepted as the cost of reliable memory headroom; offset by single-NAT staging, on-demand DynamoDB,
  db.t3.micro RDS in staging, and a 1-year commitment plan (see ADR cost analysis / `docs/cost-analysis.md`).
- Flex instances rely on CPU credits under *sustained* saturation; mitigated by HPA + Cluster Autoscaler
  adding nodes before credits deplete.

## Alternatives Considered

- **t3.medium (general-purpose, burstable) — rejected.** Cheapest (~$30/mo) but only 4 GiB RAM; with system pods
  plus 5 services on a node at minimum scale (2 nodes), memory headroom is thin and a single memory spike risks
  eviction. The hard burstable-CPU credit model is also less forgiving than m7i-flex under load.
- **c7i.large (compute-optimised) — rejected.** Excellent sustained CPU, but CloudMart is memory- rather than
  CPU-bound, and at 4 GiB / 1:2 ratio it offers less RAM than m7i-flex for ~90% of the price. Poor fit for the workload shape.
- **m7g.large (ARM / Graviton3) — rejected despite ~15% lower price.** Same 2 vCPU / 8 GiB and the best raw price,
  but our container images are built `linux/amd64` only. Adopting Graviton would force multi-arch (`buildx`) image
  builds across all five services and re-validation of every base image and dependency — operational cost that
  outweighs the ~$10/node/month saving for a project of this size. Documented as a clear future optimisation
  if a multi-arch pipeline is introduced.

## Implementation Notes

The instance type is set in `infra/modules/eks/variables.tf`:
```hcl
variable "node_instance_type" { default = "m7i-flex.large" }
```

Staging uses 2–4 nodes; Prod uses 2–6 nodes, controlled by `eks_min_nodes` / `eks_max_nodes` in `terraform.tfvars`.
