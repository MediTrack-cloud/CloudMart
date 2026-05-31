# ADR-003: Deployment Strategy for Product Service

**Date:** 2025-01-15
**Status:** Accepted
**Deciders:** CloudMart Platform Team

---

## Context

The `product-service` is the highest-read-volume service in CloudMart — every page load, search, and order placement queries it. Deploying a bad version can directly impact all user-facing features.

We need a deployment strategy that:
- Minimises capacity loss and user impact during a release
- Allows automated rollback when a release is unhealthy
- Does not require double the resources (blue/green is expensive for a student project)
- Integrates cleanly with the existing Kubernetes-on-EKS + GitHub Actions setup
- Matches CloudMart's current scale and the team's operational maturity

The brief lists **Argo Rollouts / Flagger canary** as a *distinction* option, but also requires a working, health-gated rolling deployment as the mandatory baseline.

## Considered Options

| Strategy | Tool | Capacity during deploy | Resource Cost | Rollback | Complexity |
|----------|------|------------------------|---------------|----------|------------|
| **Rolling update** | **Kubernetes native** | **No loss (`maxUnavailable:0`)** | **Low (+1 surge pod)** | **Automated (`rollout undo`)** | **Low** |
| Canary | Argo Rollouts | No loss (20% → 100%) | Low (+1–2 pods) | Fast (abort) | Medium — extra controller + CRDs + CLI plugin |
| Blue/Green | Argo Rollouts | No loss | High (2× pods) | Instant | Medium |
| Feature flags | LaunchDarkly / AWS AppConfig | No loss | Medium | Instant | High |

## Decision

**Use a health-gated Kubernetes rolling update** (`strategy.rollingUpdate: maxSurge:1, maxUnavailable:0`) for `product-service` in both staging and production, driven by the GitHub Actions CD pipeline.

How it works:
1. CD bumps the image tag in the Kustomize overlay and applies it (`kustomize build … | kubectl apply -f -`).
2. Kubernetes brings up a new pod (`maxSurge:1`) and **only retires an old pod once the new one passes its readiness probe** (`maxUnavailable:0`) — so capacity never drops.
3. The pipeline **gates** on `kubectl rollout status deployment/product-service --timeout=300s`.
4. On any failure (rollout timeout or smoke-test failure) the pipeline runs **`kubectl rollout undo`**, automatically reverting to the last good ReplicaSet.

Rationale:
- **No capacity loss**: `maxUnavailable:0` + readiness gating means users never hit an unready pod.
- **Automated rollback**: `rollout undo` on failure — no manual intervention.
- **Cost efficient**: a single surge pod during the deploy, not a second fleet (blue/green) or a parallel canary stack + controller.
- **Right-sized complexity**: no extra controller, CRDs, or `kubectl` plugin to install and operate — appropriate for CloudMart's current traffic and team size.

## Consequences

**Positive:**
- Zero-downtime deploys for the highest-traffic service, with automatic revert on failure.
- CD integrates with plain `kubectl` — no extra controller or CLI plugin (this also removed a class of pipeline failures).
- `product-service` is a standard `Deployment`, identical in staging and prod, so behaviour is uniform and easy to reason about.

**Negative:**
- A bad release briefly reaches **all** traffic before the rollout-status / smoke-test gate trips and reverts, whereas a canary would have limited it to a fraction first. Mitigated by readiness probes, the health gate, and automatic rollback.
- No gradual traffic shifting or per-step metric analysis.

## Alternatives Considered

- **Canary (Argo Rollouts) — rejected.** Lowest blast radius and a graded distinction, but it requires the Argo Rollouts controller, a `Rollout` CRD replacing the Deployment, and the `kubectl argo rollouts` CLI plugin in CI — operational overhead disproportionate to CloudMart's current scale. Documented as a planned future improvement once traffic justifies it.
- **Blue/Green — rejected.** Instant rollback but needs a full second fleet (2× pods), too costly for the budget.
- **Feature flags — rejected.** Powerful for app-level rollout but solves a different problem (per-feature toggles) and adds a third-party dependency.

## Implementation Notes

- Strategy is set in `k8s/base/product-service/deployment.yaml`:
  ```yaml
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  ```
- CD apply + health gate (`.github/workflows/cd-prod.yml`):
  ```bash
  kustomize build --load-restrictor LoadRestrictionsNone k8s/overlays/prod | kubectl apply -f -
  kubectl rollout status deployment/product-service -n cloudmart-prod --timeout=300s
  ```
- Rollback on failure: `kubectl rollout undo deployment/product-service -n cloudmart-prod`.
