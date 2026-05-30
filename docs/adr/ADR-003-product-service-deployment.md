# ADR-003: Deployment Strategy for Product Service

**Date:** 2025-01-15
**Status:** Accepted
**Deciders:** CloudMart Platform Team

---

## Context

The `product-service` is the highest-read-volume service in CloudMart — every page load, search, and order placement queries it. Deploying a bad version can directly impact all user-facing features.

We need a deployment strategy that:
- Minimises blast radius during a bad release
- Allows automated or manual rollback
- Does not require double the resources (blue/green is expensive for a student project)
- Integrates with the existing Kubernetes on EKS setup
- Satisfies the distinction requirement for advanced deployment techniques

The assignment specifically mentions **Argo Rollouts or Flagger for canary** as a distinction requirement.

## Considered Options

| Strategy | Tool | Blast Radius | Resource Cost | Rollback Speed | Complexity |
|----------|------|-------------|---------------|----------------|------------|
| Rolling update | Kubernetes native | Medium (old + new run concurrently) | Low (1 extra pod) | Slow (manual undo) | Low |
| **Canary** | **Argo Rollouts** | **Low (20% initially)** | **Low (+1–2 pods)** | **Fast (abort command)** | **Medium** |
| Blue/Green | Argo Rollouts | Very low (zero downtime) | High (2× pods) | Instant | Medium |
| Feature flags | LaunchDarkly / AWS AppConfig | Very low | Medium | Instant | High |

## Decision

**Use Argo Rollouts with a canary strategy: 20% → 40% → 100%, with CloudWatch-based analysis.**

Canary steps (defined in `k8s/argo-rollouts/product-service-rollout.yaml`):
1. Deploy canary at **20%** of traffic
2. Pause 1 minute — observe error rate via AnalysisTemplate
3. Advance to **40%** traffic
4. Pause 1 minute — final check
5. Promote to **100%** — old version is scaled down

The AnalysisTemplate queries CloudWatch for `HTTPCode_Target_5XX_Count / RequestCount`. If the success rate drops below 99% (i.e. error rate exceeds 1%) during any step, the rollout is automatically aborted and the canary is rolled back.

Rationale:
- **Low blast radius**: only 20% of users see the new version initially — a bug affects 1 in 5 requests, not all
- **Automated safety**: CloudWatch analysis prevents promotion if error rate exceeds threshold — no manual monitoring needed during deployment
- **Cost efficient**: requires only 1–2 extra pods during the canary window (~5 minutes), not double the full fleet
- **Distinction requirement**: satisfies the assignment's requirement for Argo Rollouts canary
- **Fast rollback**: `kubectl argo rollouts abort product-service` immediately reverts to 0% canary traffic

## Consequences

**Positive:**
- Reduced deployment risk for the highest-traffic service
- Automated rollback on error threshold breach
- CD pipeline integrates cleanly: `kubectl argo rollouts set image product-service ...` triggers canary
- Demo value: the progressive weight change is visible in the Argo Rollouts dashboard

**Negative:**
- Requires Argo Rollouts controller installed in the cluster (~150MB memory)
- The `product-service` Deployment in prod is replaced by a Rollout resource — kubectl rollout commands do not apply directly; must use `kubectl argo rollouts` commands
- For staging, a standard Deployment is used (canary is only meaningful in prod)

## Implementation Notes

- Controller installation: `k8s/helm-values/argo-rollouts.yaml` (deployed via ArgoCD or Helm)
- Rollout manifest: `k8s/argo-rollouts/product-service-rollout.yaml`
- Trigger in CD pipeline (`.github/workflows/cd-prod.yml`):
  ```bash
  kubectl argo rollouts set image product-service \
    product-service=<ECR_IMAGE>:<SHA> -n cloudmart-prod
  ```
- Monitor: `kubectl argo rollouts get rollout product-service -n cloudmart-prod --watch`
- Abort: `kubectl argo rollouts abort product-service -n cloudmart-prod`
