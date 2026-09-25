# 05 · Release, canary & rollback

## Pipeline
`staging` (auto) → `prod` (**approval**, then canary 25 % → 50 % → 100 %, each phase auto-advances after a 90 s soak).

## Release
```bash
# after building + signing an image (04):
gcloud deploy releases create rel-<name> --delivery-pipeline shop --region $REGION \
  --source <dir with k8s/ and skaffold.yaml> --skaffold-file skaffold.yaml --images shop=$IMG \
  --gcs-source-staging-dir gs://$PROJECT-gke-build-staging/deploy-src
gcloud deploy rollouts list --release rel-<name> --delivery-pipeline shop --region $REGION
gcloud deploy releases promote --release rel-<name> --delivery-pipeline shop --region $REGION --to-target prod
gcloud deploy rollouts approve rel-<name>-to-prod-0001 --release rel-<name> --delivery-pipeline shop --region $REGION
```
*Expected:* staging `SUCCEEDED`; prod `PENDING_APPROVAL` → approve → `IN_PROGRESS (canary-25)` → `(canary-50)` → `stable` → `SUCCEEDED`.

Watch pods shift during the canary:
```bash
kubectl -n shop-prod get pods -L deploy.cloud.google.com/release-id -w
curl -s http://$GW_IP/version
```

## Bad-release drill (what the canary is for)
```bash
./scripts/demo-bad-release.sh
```
It builds a *signed* release that fails 50 % of `/api/*`, promotes it, measures the user-visible 5xx rate during the canary (**≈ 25 % × 50 % ≈ 12 %, not 50 %**), then rolls prod back and re-measures. The `5xx ratio > 5 %` PromQL alert fires during the soak.

## Manual rollback (any time)
```bash
gcloud deploy targets rollback prod --delivery-pipeline shop --region $REGION     # to the previous good release
gcloud deploy rollouts cancel <rollout> --release <rel> --delivery-pipeline shop --region $REGION   # stop a canary mid-flight
```

## Why no HPA in prod
The canary controller sets replica counts; an HPA would fight it ([ADR 0005](../adr/0005-canary-and-hpa.md)). Staging has the HPA and the load test.
