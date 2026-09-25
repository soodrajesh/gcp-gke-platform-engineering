#!/usr/bin/env bash
# Bad-release drill: ship a build that fails 50% of API calls, watch the canary expose it to only
# ~25% of traffic, measure the damage, then roll prod back to the last good release.
source "$(dirname "$0")/lib.sh"
need gcloud; need terraform; need curl
tf_init >/dev/null; resolve_suffix
GW_IP="$($TF output -raw gateway_ip)"; REPO="$($TF output -raw artifact_repo)"; BUCKET="$($TF output -raw build_staging_bucket)"
KEYVER="$($TF output -raw signing_key_version)"; ATTESTOR="$($TF output -raw attestor)"
KEYRING="$(sed -E 's|.*/keyRings/([^/]+)/.*|\1|' <<<"$KEYVER")"; KEY="$(sed -E 's|.*/cryptoKeys/([^/]+)/.*|\1|' <<<"$KEYVER")"; KVER="$(sed -E 's|.*/cryptoKeyVersions/([0-9]+)$|\1|' <<<"$KEYVER")"

err_rate() { # <requests>  -> percentage of /api/products calls that returned 5xx
  local n="$1" bad=0 i c
  for i in $(seq 1 "$n"); do c=$(curl -s -o /dev/null -w '%{http_code}' "http://$GW_IP/api/products"); [ "${c:0:1}" = 5 ] && bad=$((bad+1)); sleep 0.6; done
  echo $(( bad * 100 / n ))
}

log "Baseline: error rate on prod before the bad release"
echo "  5xx: $(err_rate 30)%"

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

log "Canary is live at 25%: measuring what users see"
sleep 45
RATE="$(err_rate 40)"; echo "  5xx during canary: ${RATE}%  (expected ≈ 25% × 50% ≈ 12%, not 50%)"
if [ "$RATE" -ge 5 ]; then
  log "Above the 5% guard -> rolling prod back to the previous good release"
  gcloud deploy rollouts cancel "$REL-to-prod-0001" --release "$REL" --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  gcloud deploy targets rollback prod --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --quiet >/dev/null
  sleep 60
  log "After rollback"; echo "  5xx: $(err_rate 30)%"; curl -s "http://$GW_IP/version"; echo
else warn "error rate below the guard; nothing to roll back"; fi
