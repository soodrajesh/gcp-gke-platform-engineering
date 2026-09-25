# Runbooks

Each runbook: **When** · **Commands** · **Output** · **If it goes wrong**.

> **Output status.** Blocks headed *Captured* are real output. Blocks headed *Expected* describe what a healthy system prints and are replaced with *Captured* output after the first live run (`./scripts/up.sh` writes `docs/test-results.md`). No output here is invented: if a block is not marked *Captured*, treat it as a specification.

Set once per shell:
```bash
export PROJECT=$(gcloud config get-value project) REGION=europe-west1 CLUSTER=platform-eu
gcloud container clusters get-credentials $CLUSTER --region $REGION --project $PROJECT
export GW_IP=$(terraform -chdir=terraform output -raw gateway_ip)
```

| # | Runbook | Use it when |
|---|---|---|
| 01 | [Build & teardown](01-build-and-teardown.md) | Standing the platform up / down |
| 02 | [Access the cluster & Argo CD](02-access.md) | kubectl auth, authorized networks, Argo UI |
| 03 | [Change the platform via GitOps](03-gitops-changes.md) | New namespace/policy/route; drift |
| 04 | [Supply chain: build, sign, verify](04-supply-chain.md) | Shipping an image; a pod is denied by Binary Authorization |
| 05 | [Release, canary & rollback](05-release-and-rollback.md) | Promoting to prod; bad release |
| 06 | [Onboard a tenant & policy tests](06-tenancy-and-policy.md) | New team; a policy denies something |
| 07 | [Incident response](07-incident-response.md) | Alert fires; user-visible errors |
| 08 | [Cost & capacity](08-cost-and-capacity.md) | Bill questions; scaling |
| 09 | [Troubleshooting](09-troubleshooting.md) | Failures (including ones already hit during development) |
