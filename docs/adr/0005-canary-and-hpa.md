# ADR 0005 — Pod-count canary with service networking; HPA only in staging

**Status:** accepted

## Context
Cloud Deploy supports canary via a service mesh / Gateway traffic split, or via *service networking* (Deployment scaled to a percentage of pods behind the same Service).

## Decision
Service-networking canary: prod runs 4 replicas; the canary phase runs ~25 % / 50 % of pods behind the same Service and load balancer, then 100 %. Phases auto-advance after a 90 s soak (`google_clouddeploy_automation`), and a human/alert can cancel and roll back during it. **No HPA in prod**, because the canary controller sets replica counts and an HPA would fight it; the HPA and load test live in staging.

## Consequences
* No mesh to operate; the blast radius of a bad build is measurable: ≈ canary% × failure rate (`scripts/demo-bad-release.sh` demonstrates 25 % × 50 % ≈ 12 %).
* Traffic split is proportional to pod count, not exact percentages.
* **Trade-off:** fixed prod replicas. Production evolution: Gateway API weighted `HTTPRoute` canary (exact percentages) + HPA/VPA, once Cloud Deploy Gateway canary is adopted.
