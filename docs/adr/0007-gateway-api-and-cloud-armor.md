# ADR 0007 — Gateway API on a shared global external ALB, with Cloud Armor

**Status:** accepted

## Decision
One `Gateway` (`gke-l7-global-external-managed`) in a platform-owned namespace with a static, Terraform-reserved IP. Tenants attach `HTTPRoute`s from their own namespaces (only namespaces labelled `gateway-access=true`), and a `GCPBackendPolicy` attaches the Cloud Armor policy (OWASP SQLi/XSS rules at sensitivity 1 + 120 req/min/IP throttle).

## Consequences
* Role-oriented model: platform owns the entry point and WAF; app teams own routing. One LB, one IP, one WAF policy.
* Tenants cannot create `LoadBalancer`/`NodePort` Services (admission policy, ADR 0006), so nothing bypasses the WAF.
* **Not done here:** TLS. A managed certificate needs a hostname; the endpoint is HTTP on the reserved IP. Production: Certificate Manager cert + HTTPS listener + HTTP→HTTPS redirect.
