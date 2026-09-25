# ADR 0008 — Namespace-per-team tenancy with keyless, per-tenant cloud identity

**Status:** accepted

## Decision
Each tenant is a namespace carrying: Pod Security `restricted`, `ResourceQuota` + `LimitRange`, default-deny NetworkPolicy (ingress and egress) with explicit allows, admission policies, a `team`/`cost-center` label (cost attribution by namespace/label via GKE cost allocation), and its own Kubernetes ServiceAccount. Access to Google Cloud is granted in Terraform **directly to the Workload Identity principal** (`ns/<ns>/sa/<name>`) — no Google service account, no keys.

## Consequences
* Cross-tenant traffic and cross-tenant cloud access are denied by default; `scripts/test.sh` proves both (team-a reads its bucket, team-b gets 403; team-a cannot reach team-b's service).
* Soft multi-tenancy: shared control plane and kernel. For hostile tenants, use separate clusters or sandboxed nodes (GKE Sandbox) — noted, not needed here.
