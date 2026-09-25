# 09 · Troubleshooting

Entries marked **found in development** were real bugs caught while building this repo (by plan review, a local Kubernetes API server, or script review) *before* the first live run.

## Found on the first live deployment
<a id="l1"></a>
### L1 · `Resource usage export is not supported for Autopilot clusters`
`resource_usage_export_config` (GKE usage metering → BigQuery) is rejected on Autopilot. **Fix:** removed; cost attribution uses `cost_management_config` + enforced `team` labels, visible in Cloud Billing reports.

### L2 · `The following PromQL metric(s) are invalid: http_requests_total`
Cloud Monitoring validates PromQL alert queries against metrics that already exist; a metric that has never been written is "invalid", so the alert can't be created in the first apply. **Fix:** `enable_app_alerts` (default false); `up.sh` waits until Managed Prometheus has scraped the app, then applies with `enable_app_alerts=true`.

<a id="l3"></a>
### L3 · Argo app `platform-policies` stuck `OutOfSync` after a successful sync
GKE's admission controller injects `spec.matchConstraints.namespaceSelector` into every `ValidatingAdmissionPolicy` (exempting its managed namespaces `kube-system`, `gke-gmp-system`, …). Argo CD sees the live object differ from git forever. **Fix:** `ignoreDifferences` on that one field + `RespectIgnoreDifferences=true`. Diagnose with `kubectl -n argocd get application <app> -o json | jq '.status.resources[] | select(.status!="Synced")'`.

<a id="l4"></a>
### L4 · Cloud Build scan step: `requires the installation of components: [local-extract]`
The `cloud-sdk:slim` builder image has no scanner component and its component manager is disabled. **Fix:** `apt-get install google-cloud-cli-local-extract` at the start of the step; if scanning is still unavailable the step warns loudly and continues unless `_BLOCK_ON_CRITICAL=true`.

## Found in development
### D1 · Argo CD's Redis would have been blocked by Binary Authorization
`helm template` showed the chart pulls Redis from `ecr-public.aws.com/docker/library/redis`, not `public.ecr.aws`. The allow-list only had the latter, so Argo CD's Redis pod would be denied and the whole GitOps layer never start. **Fix:** add `ecr-public.aws.com/docker/library/*`. **Lesson:** derive allow-lists from `helm template | grep image:`, never from memory.

### D2 · Default-deny egress also blocked same-namespace traffic
The `allow-baseline` policy allowed ingress from the same namespace but had no matching egress rule, so pods couldn't call each other (the load generator couldn't reach `shop`). **Fix:** egress `to: podSelector: {}`.

### D3 · Re-run logic treated a live deployment as "fresh" (repo `gcp-enterprise-rag-platform`)
`grep -q` closing the pipe SIGPIPE'd `terraform state list` under `pipefail`, so the resource-suffix logic thought no state existed and planned to rebuild under new names. **Fix:** capture output before `grep`. Caught by running `up.sh --plan`.

### D4 · Terraform wanted to replace CMEK BigQuery tables (repo `gcp-enterprise-rag-platform`)
Tables inherit CMEK from the dataset but state recorded it; the config omitted it → "forces replacement" (data loss). **Fix:** declare `encryption_configuration` explicitly. Caught by reading the plan.

### D5 · `validate` ≠ works: policy tests on a real API server
Static schema validation passes malformed CEL. The admission policies were therefore tested on a real API server (kind) with 9 deny/allow cases, and the suite was verified to go red when a policy is removed.

## Likely first-run issues
| Symptom | Cause | Fix |
|---|---|---|
| `Unable to connect to the server: dial tcp ... i/o timeout` | Your IP is not in authorized networks | [02](02-access.md) |
| Argo app `platform-gateway` stuck `Progressing` | External ALB still provisioning (3–5 min) or named address missing | `kubectl describe gateway external -n platform-gateway`; `gcloud compute addresses list --global` |
| Gateway `Accepted` but 404/502 | HTTPRoute not yet attached / NEG not healthy | `kubectl get httproute -A`; backend health in Console |
| `gcloud deploy releases create` → permission denied acting as executor | Missing `iam.serviceAccountUser` on `plat-deploy-exec` | Re-run `up.sh` (Terraform grants it to the admin) |
| Cloud Deploy rollout `FAILED` at deploy | Cloud Deploy can't reach the API server | Ensure `gcp_public_cidrs_access_enabled` is on ([02](02-access.md)) |
| Pod `Denied by Binary Authorization` for the app image | Attestation missing/for another digest | [04](04-supply-chain.md) |
| `terraform destroy` fails deleting the VPC / Cloud Armor policy ("in use") | Gateway-created LB/NEGs still exist | Use `./scripts/down.sh` (removes them first) |
| KMS / WIF pool "already exists" on rebuild | 30-day non-reusable names | `up.sh` uses a fresh `.deploy-suffix`; don't copy an old one |
