# ADR 0003 — Control-plane access: authorized networks + Google public IPs (not a private endpoint)

**Status:** accepted for the demo; hardening path documented

## Context
Cloud Deploy and Cloud Build must reach the Kubernetes API. With a *private endpoint* that requires a Cloud Build/Cloud Deploy **private pool** peered into the VPC (fixed cost, more moving parts).

## Decision
Private **nodes**, public **endpoint** restricted by `master_authorized_networks`: the operator's /32 plus `gcp_public_cidrs_access_enabled` (Google Cloud public IPs, which include Cloud Deploy). Access is still IAM-authenticated and RBAC-authorised.

## Consequences
* No standing infrastructure for private pools; simple to rebuild from one script.
* The API server is reachable from any Google Cloud IP *to attempt* authentication — a wider exposure than a private endpoint.
* **Production path:** private endpoint + Cloud Deploy/Cloud Build private pools + IAP/Connect gateway for humans. The Terraform variables are already isolated in `modules/gke`.
