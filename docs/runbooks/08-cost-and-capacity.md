# 08 · Cost & capacity

Autopilot bills **per pod request** (vCPU, memory, ephemeral storage) plus a cluster management fee (covered by the free-tier credit for one cluster). Cost tracks workload; idle capacity isn't billed as nodes.

Main line items while the platform is up: Autopilot pod requests · Cloud NAT · global forwarding rule + Cloud Armor policy/rules · KMS · Cloud Build minutes · logging volume. **A demo left running a day costs a few euros; `./scripts/down.sh` stops all of it.**

## Cost by namespace / team
GKE usage metering exports to BigQuery (`gke_usage`), and pods carry `team` labels (enforced by policy):
```bash
bq ls --project_id=$PROJECT gke_usage
bq query --use_legacy_sql=false --location=$REGION \
 'SELECT namespace, SUM(usage.amount) AS usage FROM `'$PROJECT'.gke_usage.gke_cluster_resource_consumption` WHERE resource_name IN ("cpu","memory") GROUP BY namespace ORDER BY usage DESC'
```

## Guardrails
* Budget `gke-platform monthly guardrail` alerts at 25/50/90/100 %.
* `ResourceQuota` per tenant caps requests and forbids `LoadBalancer` Services.
* Cloud Deploy prod is fixed at 4 replicas; only staging autoscales (max 10).

## Capacity
`kubectl -n shop-staging get hpa shop` (2–10 pods at 60 % CPU). Quota headroom: `gcloud compute regions describe $REGION --format='value(quotas)'`.
