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

## Bad-release drill — *Captured* (live GKE, `./scripts/demo-bad-release.sh`)
It builds a **signed** release that fails 50 % of `/api/*`, promotes it, samples what real users see in each canary phase (60 requests per endpoint per phase, kept under the Cloud Armor 120 req/min throttle), then cancels, rolls back, approves the rollback and verifies recovery.
```
==> Baseline: error rate on prod before the bad release
  API calls that returned 5xx: 0%
==> Canary phases: waiting for canary pods, then measuring what users actually see
  phase 1: canary pods 1 / stable 3  (pod share 25%)
      responses from the faulty build: 25%   ·   API calls that returned 5xx: 10%
  phase 2: canary pods 2 / stable 2  (pod share 50%)
      responses from the faulty build: 48%   ·   API calls that returned 5xx: 20%
==> Faulty build is hurting users -> cancel the canary and roll prod back
✔ approved rollback rel-v260925-231528-to-prod-0002
✔ rollback SUCCEEDED
==> After rollback
  responses from the faulty build: 0%   ·   API calls that returned 5xx: 0%
{"version":"v260925-231528","error_rate":0.0,"pod":"shop-9979494c4-p6fjt"}
```
**Reading it:** exposure to the bad build tracks the canary's pod share (25 % → 25 %, 50 % → 48 %), so the user-visible failure rate is ≈ pod share × the build's 50 % failure rate (measured 10 % and 20 %; sampling noise on 60 requests is a few points). Without a canary all 100 % of users would see 50 % errors. Recovery: 0 % / 0 %.

### Two things this drill taught (both real)
1. **A rollback in prod needs approval too.** `require_approval` applies to *every* rollout on the target, rollbacks included. `gcloud deploy targets rollback prod` therefore creates a rollout in `PENDING_APPROVAL`; until someone approves it **the bad build keeps serving**. The first attempt of this drill cancelled the canary and stopped there, which left prod on the faulty build until the rollback was approved. In an incident, do both steps:
   ```bash
   gcloud deploy targets rollback prod --delivery-pipeline shop --region $REGION
   gcloud deploy rollouts list --delivery-pipeline shop --release <rel> --region $REGION   # find the PENDING_APPROVAL one
   gcloud deploy rollouts approve <rollback-rollout> --release <rel> --delivery-pipeline shop --region $REGION
   ```
   (If a faster path is worth more than a second approver during incidents, put rollbacks behind a separate target or an automation with `promote`/`repair` rules — a trade-off to decide deliberately.)
2. **Measure after the canary is actually serving.** The first attempt sampled 45 s in, before the canary pods were ready, and reported 0 %. Wait for the canary pods, then sample; compare the *build* served (`/version`) with the *5xx* rate.

## Manual rollback (any time)
```bash
gcloud deploy targets rollback prod --delivery-pipeline shop --region $REGION     # to the previous good release
gcloud deploy rollouts cancel <rollout> --release <rel> --delivery-pipeline shop --region $REGION   # stop a canary mid-flight
```

## Why no HPA in prod
The canary controller sets replica counts; an HPA would fight it ([ADR 0005](../adr/0005-canary-and-hpa.md)). Staging has the HPA and the load test.
