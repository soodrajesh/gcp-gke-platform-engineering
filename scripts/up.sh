#!/usr/bin/env bash
# Build the whole platform end to end, then prove it works:
#   state bucket -> infra (VPC, Autopilot, BinAuthz, Cloud Deploy, WAF, monitoring) -> Argo CD + GitOps
#   -> secure image build + attestation -> Cloud Deploy staging -> prod canary -> live tests.
# Idempotent. `--plan` shows the Terraform plan and stops. `--skip-tests` skips the final test suite.
source "$(dirname "$0")/lib.sh"
PLAN_ONLY=0; SKIP_TESTS=0
for a in "$@"; do case "$a" in --plan) PLAN_ONLY=1;; --skip-tests) SKIP_TESTS=1;; esac; done
need gcloud; need terraform; need kubectl; need helm; need curl; need python3
command -v gke-gcloud-auth-plugin >/dev/null || die "gke-gcloud-auth-plugin missing" "gcloud components install gke-gcloud-auth-plugin"

log "Project $PROJECT_ID · $REGION · cluster $CLUSTER · billing $BILLING_ACCOUNT_ID · admin $ADMIN_EMAIL"

log "1/9 Terraform state bucket"
"$ROOT/scripts/bootstrap.sh" "$PROJECT_ID" "$REGION" >/dev/null && ok "gs://$STATE_BUCKET"
tf_init; resolve_suffix; set_authorized_cidr
ok "resource suffix '${TF_VAR_resource_suffix}' · kubectl allowed from ${TF_VAR_authorized_cidr}"

# Argo CD reconciles from GitHub, so what is *pushed* is what gets deployed.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 && git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  git -C "$ROOT" fetch -q origin main 2>/dev/null || true
  if [ -n "$(git -C "$ROOT" status --porcelain gitops 2>/dev/null)" ] || \
     [ "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" != "$(git -C "$ROOT" rev-parse origin/main 2>/dev/null || echo x)" ]; then
    warn "local commits/changes are not on origin/main — Argo CD will deploy what is on GitHub, not your working tree"
  fi
fi

if [ "$PLAN_ONLY" = 1 ]; then log "Plan only"; $TF plan -input=false; exit 0; fi

log "2/9 Infrastructure (Autopilot cluster takes ~8-10 min)"
$TF apply -input=false -auto-approve
out() { $TF output -raw "$1"; }
REPO="$(out artifact_repo)"; GW_IP="$(out gateway_ip)"; BUCKET="$(out build_staging_bucket)"
KEYVER="$(out signing_key_version)"; ATTESTOR="$(out attestor)"
KEYRING="$(sed -E 's|.*/keyRings/([^/]+)/.*|\1|' <<<"$KEYVER")"; KEY="$(sed -E 's|.*/cryptoKeys/([^/]+)/.*|\1|' <<<"$KEYVER")"
KVER="$(sed -E 's|.*/cryptoKeyVersions/([0-9]+)$|\1|' <<<"$KEYVER")"

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  for kv in "WIF_PROVIDER=$(out wif_provider)" "CI_PLAN_SA=$(out ci_plan_sa)" "CI_DEPLOY_SA=$(out ci_deploy_sa)" \
            "GCP_PROJECT=$PROJECT_ID" "BILLING_ACCOUNT=$BILLING_ACCOUNT_ID" "ALERT_EMAIL=$ALERT_EMAIL"; do
    gh variable set "${kv%%=*}" -R "$GITHUB_REPO" -b "${kv#*=}" >/dev/null 2>&1 || true
  done
  gh api -X PUT "repos/$GITHUB_REPO/environments/prod" --silent >/dev/null 2>&1 || true
  ok "GitHub Actions variables set on $GITHUB_REPO"
fi

log "3/9 Cluster credentials"
cluster_credentials; ok "$(kubectl config current-context)"
wait_for "API server reachable" 300 kubectl get --raw /healthz

log "4/9 Argo CD (GitOps) + platform layer"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true; helm repo update argo >/dev/null
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install argocd argo/argo-cd --version 10.9.2 -n argocd -f gitops/bootstrap/argocd-values.yaml --wait --timeout 10m >/dev/null
ok "Argo CD installed"
kubectl apply -f gitops/bootstrap/project.yaml -f gitops/bootstrap/root.yaml >/dev/null
for app in platform-namespaces platform-policies platform-tenants platform-monitoring platform-gateway; do
  wait_for "Argo app $app Synced" 600 bash -c "[ \"\$(kubectl -n argocd get application $app -o jsonpath='{.status.sync.status}')\" = Synced ]"
done
wait_for "Gateway programmed (external ALB, ~3-5 min)" 900 bash -c \
  "[ \"\$(kubectl -n platform-gateway get gateway external -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}')\" = True ]"

log "5/9 Secure build: build -> scan -> sign (Binary Authorization attestation)"
TAG="v$(date +%y%m%d-%H%M%S)"
gcloud builds submit --project "$PROJECT_ID" --region "$REGION" --config cloudbuild.yaml \
  --service-account "projects/$PROJECT_ID/serviceAccounts/plat-build@$PROJECT_ID.iam.gserviceaccount.com" \
  --gcs-source-staging-dir "gs://$BUCKET/src" \
  --substitutions "_REPO=$REPO,_TAG=$TAG,_ATTESTOR=$ATTESTOR,_KMS_LOCATION=$REGION,_KMS_KEYRING=$KEYRING,_KMS_KEY=$KEY,_KMS_VERSION=$KVER" . 
DIGEST="$(gcloud artifacts docker images describe "$REPO/shop:$TAG" --format='get(image_summary.digest)')"
IMG="$REPO/shop@$DIGEST"; ok "signed image $IMG"
echo "$IMG" > "$ROOT/.last-image"

log "6/9 Cloud Deploy: release -> staging"
SRC="$(mktemp -d)"; cp -R k8s skaffold.yaml "$SRC/"
REL="rel-$(tr 'A-Z_.' 'a-z--' <<<"$TAG")"
gcloud deploy releases create "$REL" --project "$PROJECT_ID" --region "$REGION" --delivery-pipeline shop \
  --source "$SRC" --skaffold-file skaffold.yaml --images "shop=$IMG" --gcs-source-staging-dir "gs://$BUCKET/deploy-src" >/dev/null
rm -rf "$SRC"
rollout_state() { gcloud deploy rollouts describe "$1" --release "$REL" --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --format='value(state)' 2>/dev/null; }
wait_state() { # <rollout> <want> <timeout>
  local end=$(( $(date +%s) + $3 )) s
  while :; do s="$(rollout_state "$1")"
    [ "$s" = "$2" ] && { ok "$1 -> $2"; return 0; }
    case "$s" in FAILED|CANCELLED) die "$1 ended $s";; esac
    [ "$(date +%s)" -lt "$end" ] || die "timeout: $1 is '$s', wanted $2"; sleep 10; done; }
wait_state "$REL-to-staging-0001" SUCCEEDED 900

log "7/9 Promote to prod: human approval, then 25% -> 50% -> 100% canary (auto-advance after a 90s soak)"
gcloud deploy releases promote --release "$REL" --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --to-target prod --quiet >/dev/null
wait_state "$REL-to-prod-0001" PENDING_APPROVAL 300
gcloud deploy rollouts approve "$REL-to-prod-0001" --release "$REL" --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --quiet >/dev/null
ok "approved"
wait_state "$REL-to-prod-0001" SUCCEEDED 1500

log "8/9 Public endpoint"
wait_for "http://$GW_IP/healthz answers 200" 600 bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://$GW_IP/healthz)\" = 200 ]"
curl -s "http://$GW_IP/version"; echo

log "8b/9 App alerts (need the metric to exist: wait for Managed Prometheus to scrape the app)"
for _ in $(seq 1 30); do curl -s "http://$GW_IP/api/products" >/dev/null; sleep 2; done
wait_for "http_requests_total visible in Cloud Monitoring PromQL" 600 bash -c \
  "curl -s -G -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" -H 'x-goog-user-project: $PROJECT_ID' 'https://monitoring.googleapis.com/v1/projects/$PROJECT_ID/location/global/prometheus/api/v1/query' --data-urlencode 'query=http_requests_total{namespace=\"shop-prod\"}' | grep -q '\"value\"'"
$TF apply -input=false -auto-approve -var enable_app_alerts=true >/dev/null && ok "5xx-ratio alert created"

if [ "$SKIP_TESTS" = 0 ]; then
  log "9/9 Live test suite"
  RUN_LOAD=1 "$ROOT/scripts/test.sh"
fi

log "DONE"
echo "  Shop (prod):    http://$GW_IP/         staging: http://$GW_IP/staging/"
echo "  Argo CD UI:     kubectl -n argocd port-forward svc/argocd-server 8081:80   (admin / \$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d))"
echo "  Bad-release drill:  ./scripts/demo-bad-release.sh"
echo "  Tear down:          ./scripts/down.sh"
