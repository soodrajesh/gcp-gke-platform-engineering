#!/usr/bin/env bash
# Bad-release drill: ship a build that fails 50% of API calls, watch the canary expose it to only
# ~25% of traffic, measure the damage, then roll prod back to the last good release.
source "$(dirname "$0")/lib.sh"
need gcloud; need terraform; need curl
tf_init >/dev/null; resolve_suffix
GW_IP="$($TF output -raw gateway_ip)"; REPO="$($TF output -raw artifact_repo)"; BUCKET="$($TF output -raw build_staging_bucket)"
KEYVER="$($TF output -raw signing_key_version)"; ATTESTOR="$($TF output -raw attestor)"
KEYRING="$(sed -E 's|.*/keyRings/([^/]+)/.*|\1|' <<<"$KEYVER")"; KEY="$(sed -E 's|.*/cryptoKeys/([^/]+)/.*|\1|' <<<"$KEYVER")"; KVER="$(sed -E 's|.*/cryptoKeyVersions/([0-9]+)$|\1|' <<<"$KEYVER")"

# Cloud Armor throttles at 120 req/min/IP, so keep well under it: 60 requests ~ 33 s per endpoint.
sample_status() { # <n> -> "<pct of requests that returned 5xx>"
  local n="$1" bad=0 i c
  for i in $(seq 1 "$n"); do c=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$GW_IP/api/products"); [ "${c:0:1}" = 5 ] && bad=$((bad+1)); sleep 0.55; done
  echo $(( bad * 100 / n ))
}
sample_build() { # <n> -> "<pct of responses served by the faulty build>"
  local n="$1" bad=0 i v
  for i in $(seq 1 "$n"); do v=$(curl -s -m 5 "http://$GW_IP/version"); [[ "$v" == *'"error_rate":0.5'* ]] && bad=$((bad+1)); sleep 0.55; done
  echo $(( bad * 100 / n ))
}
canary_pods() { kubectl -n shop-prod get pods -l app=shop-canary --no-headers 2>/dev/null | grep -c Running || true; }
stable_pods() { kubectl -n shop-prod get pods -l app=shop --no-headers 2>/dev/null | grep -c Running || true; }
measure_phase() { # <label>
  local c s; c="$(canary_pods)"; s="$(stable_pods)"
  echo "  $1: canary pods $c / stable $s  (pod share $(( 100 * c / (c + s) ))%)"
  echo "      responses from the faulty build: $(sample_build 60)%   ·   API calls that returned 5xx: $(sample_status 60)%"
}

log "Baseline: error rate on prod before the bad release"
echo "  API calls that returned 5xx: $(sample_status 40)%"

log "Build a faulty release (ERROR_RATE=0.5), signed like any other"
TAG="bad-$(date +%y%m%d-%H%M%S)"
gcloud builds submit --project "$PROJECT_ID" --region "$REGION" --config cloudbuild.yaml \
  --service-account "projects/$PROJECT_ID/serviceAccounts/plat-build@$PROJECT_ID.iam.gserviceaccount.com" \
  --gcs-source-staging-dir "gs://$BUCKET/src" \
  --substitutions "_REPO=$REPO,_TAG=$TAG,_ERROR_RATE=0.5,_ATTESTOR=$ATTESTOR,_KMS_LOCATION=$REGION,_KMS_KEYRING=$KEYRING,_KMS_KEY=$KEY,_KMS_VERSION=$KVER" . >/dev/null
DIGEST="$(gcloud artifacts docker images describe "$REPO/shop:$TAG" --format='get(image_summary.digest)')"
SRC="$(mktemp -d)"; cp -R k8s skaffold.yaml "$SRC/"; REL="rel-$(tr '_.' '--' <<<"$TAG")"
gcloud deploy releases create "$REL" --project "$PROJECT_ID" --region "$REGION" --delivery-pipeline shop --source "$SRC" \
  --skaffold-file skaffold.yaml --images "shop=$REPO/shop@$DIGEST" --gcs-source-staging-dir "gs://$BUCKET/deploy-src" >/dev/null; rm -rf "$SRC"
state() { gcloud deploy rollouts describe "$1" --release "$REL" --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --format='value(state)' 2>/dev/null; }
until [ "$(state "$REL-to-staging-0001")" = SUCCEEDED ]; do sleep 10; done; ok "staging deployed (bad build)"
gcloud deploy releases promote --release "$REL" --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --to-target prod --quiet >/dev/null
until [ "$(state "$REL-to-prod-0001")" = PENDING_APPROVAL ]; do sleep 5; done
gcloud deploy rollouts approve "$REL-to-prod-0001" --release "$REL" --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --quiet >/dev/null

log "Canary phases: waiting for canary pods, then measuring what users actually see"
for _ in $(seq 1 60); do [ "$(canary_pods)" -ge 1 ] && break; sleep 5; done
sleep 20
measure_phase "phase 1"
PODS1="$(canary_pods)"
# the automation advances to the next phase after a 90 s soak; wait for the pod mix to change
for _ in $(seq 1 60); do [ "$(canary_pods)" != "$PODS1" ] && break; sleep 5; done
sleep 20
measure_phase "phase 2"

log "Faulty build is hurting users -> cancel the canary and roll prod back"
gcloud deploy rollouts cancel "$REL-to-prod-0001" --release "$REL" --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --quiet >/dev/null 2>&1 || true
gcloud deploy targets rollback prod --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --quiet 2>&1 | tail -1
# Production requires a human approval for EVERY rollout, rollbacks included: approve it.
RB=""; RBREL=""
for _ in $(seq 1 30); do
  for r in $(gcloud deploy releases list --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --format='value(name.basename())'); do
    n=$(gcloud deploy rollouts list --delivery-pipeline shop --release "$r" --region "$REGION" --project "$PROJECT_ID" --format='value(name.basename(),state)' 2>/dev/null | awk '$2=="PENDING_APPROVAL"{print $1}' | head -1)
    [ -n "$n" ] && { RB="$n"; RBREL="$r"; break 2; }
  done; sleep 5
done
[ -n "$RB" ] || die "rollback rollout never reached PENDING_APPROVAL"
gcloud deploy rollouts approve "$RB" --release "$RBREL" --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --quiet >/dev/null
ok "approved rollback $RB"
for _ in $(seq 1 90); do [ "$(gcloud deploy rollouts describe "$RB" --release "$RBREL" --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --format='value(state)')" = SUCCEEDED ] && break; sleep 10; done
ok "rollback SUCCEEDED"

log "After rollback"
echo "  responses from the faulty build: $(sample_build 40)%   ·   API calls that returned 5xx: $(sample_status 40)%"
curl -s "http://$GW_IP/version"; echo
