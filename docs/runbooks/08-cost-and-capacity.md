# 08 · Cost & capacity

Autopilot bills **per pod request** (vCPU, memory, ephemeral storage) plus a cluster management fee (covered by the free-tier credit for one cluster). Cost tracks workload; idle capacity isn't billed as nodes.

Main line items while the platform is up: Autopilot pod requests · Cloud NAT · global forwarding rule + Cloud Armor policy/rules · KMS · Cloud Build minutes · logging volume. **A demo left running a day costs a few euros; `./scripts/down.sh` stops all of it.**

## Cost by namespace / team
Cost allocation is enabled on the cluster and every pod carries a `team` label (enforced by admission policy), so spend is broken down by **namespace and label** in Cloud Billing: Console → Billing → Reports → *Group by: Label / GKE namespace*. (GKE usage metering export to BigQuery is **not supported on Autopilot** — found on the first live apply; see [09](09-troubleshooting.md#l1).)

## Guardrails
* Budget `gke-platform monthly guardrail` alerts at 25/50/90/100 %.
* `ResourceQuota` per tenant caps requests and forbids `LoadBalancer` Services.
* Cloud Deploy prod is fixed at 4 replicas; only staging autoscales (max 10).

## Capacity
`kubectl -n shop-staging get hpa shop` (2–10 pods at 60 % CPU). Quota headroom: `gcloud compute regions describe $REGION --format='value(quotas)'`.
