# ADR-003: Deployment Strategy for Product Service

**Date:** 2025-01-15
**Status:** Accepted
**Deciders:** CloudMart Platform Team

---

## Context

The `product-service` is the highest-read-volume service in CloudMart — every page load, search, and order placement queries it. Deploying a bad version can directly impact all user-facing features.

We need a deployment strategy that:
- Minimises blast radius during a bad release
- Allows automated rollback when a release is unhealthy
- Does not require double the resources (blue/green is expensive for a student project)
- Integrates cleanly with the existing Kubernetes-on-EKS + GitHub Actions setup
- Keeps the CD pipeline simple enough to run reliably in a viva/demo

## Considered Options

| Strategy | Tool | Blast Radius | Resource Cost | Rollback Speed | Complexity |
|----------|------|-------------|---------------|----------------|------------|
| **Rolling update + auto-rollback** | **Kubernetes native + GitHub Actions** | **Medium (old + new run concurrently, `maxUnavailable:0`)** | **Low (+1 pod)** | **Fast (`kubectl rollout undo` on smoke-test failure)** | **Low** |
| Canary | Argo Rollouts | Low (20% initially) | Low (+1–2 pods) | Fast (abort command) | Medium (extra controller + CRDs) |
| Blue/Green | Argo Rollouts | Very low (zero downtime) | High (2× pods) | Instant | Medium |
| Feature flags | LaunchDarkly / AWS AppConfig | Very low | Medium | Instant | High |

## Decision

**Use a Kubernetes-native rolling update with `maxSurge:1 / maxUnavailable:0`, gated by post-deploy smoke tests and an automatic rollback on failure** (implemented in `.github/workflows/cd-prod.yml`).

How it works (production pipeline):
1. Merge to `main` requires a **manual approval gate** (GitHub Environment reviewers).
2. A **pre-deploy Velero backup** of the namespace is taken.
3. The new image (immutable commit SHA) is applied via the Kustomize overlay. Because the
   Deployment uses `maxUnavailable:0`, Kubernetes never drops below full capacity — a new
   pod must become Ready before an old one is removed.
4. The pipeline **waits for the rollout to complete**, then runs **smoke tests** against the ALB.
5. **If any step fails, `kubectl rollout undo` automatically reverts** every deployment to the
   previous ReplicaSet.

Rationale:
- **No capacity loss**: `maxUnavailable:0` guarantees the readiness-gated rolling update keeps
  the full replica count serving throughout the deploy.
- **Automated safety**: smoke-test failure triggers an immediate, automatic rollback — no manual
  monitoring needed during deployment.
- **Cost efficient**: needs only one extra pod during the surge, not a parallel fleet.
- **Operationally simple**: relies only on stock Kubernetes + GitHub Actions. There is no extra
  controller, no CRDs, and nothing additional to install, debug, or keep healthy during a demo —
  which is exactly where the previous, more complex option kept causing problems.

## Consequences

**Positive:**
- Reliable, low-moving-parts deploys for the highest-traffic service.
- Automatic rollback on health-check/smoke-test failure.
- The CD pipeline is self-contained: image bump → apply → wait → smoke test → (rollback on fail).

**Negative:**
- A rolling update has a larger initial blast radius than a 20% canary: a bad version briefly
  serves a share of *all* traffic (mitigated by `maxUnavailable:0`, readiness gating, and fast
  automatic rollback) rather than a fixed 20% slice.
- No *gradual* traffic shifting or per-step metric analysis. If progressive, weighted rollout is
  needed later, Argo Rollouts is the documented upgrade path (see below).

## Alternatives Considered

- **Argo Rollouts canary (20→40→100%) — considered, not adopted.** A canary with a CloudWatch
  AnalysisTemplate (auto-abort on >1% error rate) gives the smallest blast radius and is an
  attractive progressive-delivery pattern. It was **dropped from the deploy path** because the
  extra controller, CRDs, and analysis wiring added operational complexity and flakiness that
  outweighed the benefit at this project's scale and traffic level; the automatic-rollback
  rolling update achieves the core safety goal (revert a bad release automatically) with far
  fewer moving parts. This remains the clear future enhancement if real, sustained traffic and
  per-step metric gating become requirements.
- **Blue/Green — rejected.** Zero-downtime and instant rollback, but requires ~2× the pods for
  the full fleet — not justified for a student-project budget.
- **Feature flags — rejected.** Highest flexibility but highest complexity, and requires an
  external SaaS or AppConfig integration that the application code does not currently use.

## Implementation Notes

- Deployment strategy: `k8s/base/product-service/deployment.yaml`
  (`strategy.rollingUpdate.maxSurge: 1`, `maxUnavailable: 0`).
- CD pipeline: `.github/workflows/cd-prod.yml` — `kubectl rollout status` wait, smoke-test job,
  and the `Rollback on failure` step (`if: failure()` → `kubectl rollout undo`).
- Trigger a deploy by merging to `main`; monitor with
  `kubectl rollout status deployment/product-service -n cloudmart-prod`.
