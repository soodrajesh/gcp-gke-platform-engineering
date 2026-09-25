# 07 · Incident response

**Alerts** (email): *shop-prod – external uptime check failing*, *shop-prod – 5xx ratio above 5 % for 5m*, *GKE – container restart loop*, budget thresholds.

## 1. Scope in two minutes
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://$GW_IP/healthz                 # is the edge up?
kubectl -n shop-prod get pods -o wide; kubectl -n shop-prod get events --sort-by=.lastTimestamp | tail
kubectl -n platform-gateway get gateway external
```
Dashboard: *GKE Platform – Golden Signals* (request rate by status, p50/p95 latency, pods, CPU).

## 2. PromQL (Managed Prometheus, via Cloud Monitoring)
```bash
q() { curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "x-goog-user-project: $PROJECT" \
  "https://monitoring.googleapis.com/v1/projects/$PROJECT/location/global/prometheus/api/v1/query" --data-urlencode "query=$1"; }
q 'sum by (code) (rate(http_requests_total{namespace="shop-prod"}[5m]))'
q 'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="shop-prod"}[5m])))'
```

## 3. Decision tree
| Signal | Likely cause | Action |
|---|---|---|
| 5xx started at a release time | Bad release | `gcloud deploy targets rollback prod ...` **first**, diagnose after ([05](05-release-and-rollback.md)) |
| 403 from the edge for real users | Cloud Armor false positive | Cloud Logging → `jsonPayload.enforcedSecurityPolicy`; tune the rule/sensitivity in Terraform |
| 429 | Rate limit (120 req/min/IP) | Expected for abusers; raise the threshold if legitimate (NAT'd offices) |
| Pods `Pending` | Autopilot provisioning / quota | `kubectl describe pod`; check `ResourceQuota` and regional quota |
| Pods denied at creation | Binary Authorization / policy | [04](04-supply-chain.md), [06](06-tenancy-and-policy.md) |
| Uptime check failing, pods healthy | Gateway/LB | `kubectl describe gateway external -n platform-gateway`; backend health in Console → Load balancing |

## 4. Logs
```bash
gcloud logging read 'resource.type="k8s_container" AND resource.labels.namespace_name="shop-prod" AND severity>=ERROR' --project $PROJECT --limit 20
gcloud logging read 'resource.type="http_load_balancer" AND httpRequest.status>=500' --project $PROJECT --limit 10
```
