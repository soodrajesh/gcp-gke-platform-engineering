# ADR 0002 — Two delivery mechanisms with a hard boundary: Argo CD for the platform, Cloud Deploy for applications

**Status:** accepted

## Context
"GitOps" and "progressive delivery" are different problems. Platform config (namespaces, quotas, policies, gateway, monitoring) should be continuously reconciled and self-healing. Application releases need promotion gates, approvals, canaries and rollback with an audit trail.

## Decision
* **Argo CD** owns `gitops/platform/**` (app-of-apps, automated prune + self-heal, scoped by an `AppProject`).
* **Cloud Deploy** owns application releases: staging (immediate) → prod (**manual approval**, then 25 % → 50 % → 100 % canary, auto-advance after a soak).
* Terraform owns everything outside the cluster (VPC, cluster, IAM, KMS, registry, WAF, alerts).

## Consequences
* Each tool does what it is best at; ownership is unambiguous, so nothing fights over the same object (e.g. no HPA in prod: canary controls replicas — ADR 0005).
* Cloud Deploy is Google-managed (IAM-native approvals, Cloud Audit Logs, no server to run); Argo CD is one small in-cluster controller used only for the platform layer.
* **Trade-off:** two mental models. Mitigated by the boundary above and by runbooks for each.
