#!/usr/bin/env bash
# Delete everything this repo created, end to end.
#   ./scripts/down.sh            destroy the platform (keeps the tiny Terraform state bucket)
#   ./scripts/down.sh --purge    also delete the state bucket (nothing of this repo is left)
# Order matters: load balancers, NEGs and firewall rules created by the *Gateway controller* live
# outside Terraform's state and would block VPC/Cloud Armor deletion, so they go first.
source "$(dirname "$0")/lib.sh"
need gcloud; need terraform
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1

log "Project $PROJECT_ID — destroying everything managed by this repo"
tf_init; resolve_suffix
export TF_VAR_authorized_cidr="$(my_ip 2>/dev/null || echo 203.0.113.1)/32"

if gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  log "1/4 Removing Kubernetes-created cloud resources (LB, NEGs, firewall rules)"
  cluster_credentials || warn "could not get cluster credentials; continuing"
  # stop GitOps first so nothing is re-created
  helm uninstall argocd -n argocd >/dev/null 2>&1 || true
  kubectl delete applications.argoproj.io --all -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete gateway --all -A --wait=true --timeout=300s >/dev/null 2>&1 || true
  kubectl delete httproute,gcpbackendpolicy,healthcheckpolicy --all -A --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace shop-staging shop-prod team-a team-b platform-gateway --wait=true --timeout=300s >/dev/null 2>&1 || true
  echo -n "  waiting for load balancer + NEG cleanup"
  for _ in $(seq 1 60); do
    left=$(gcloud compute forwarding-rules list --project "$PROJECT_ID" --global --format='value(name)' 2>/dev/null | grep -c . || true)
    negs=$(gcloud compute network-endpoint-groups list --project "$PROJECT_ID" --format='value(name)' 2>/dev/null | grep -c . || true)
    [ "${left:-0}" = 0 ] && [ "${negs:-0}" = 0 ] && break; echo -n "."; sleep 10
  done; echo; ok "Kubernetes-created cloud resources gone"
else
  warn "cluster not found; skipping Kubernetes cleanup"
fi

log "2/4 Cloud Deploy (releases/rollouts block pipeline deletion unless forced)"
gcloud deploy delivery-pipelines delete shop --force --region "$REGION" --project "$PROJECT_ID" --quiet >/dev/null 2>&1 || true
ok "pipeline removed"

log "3/4 Terraform destroy"
$TF destroy -input=false -auto-approve
ok "platform destroyed"
kubectl config delete-context "gke_${PROJECT_ID}_${REGION}_${CLUSTER}" >/dev/null 2>&1 || true
kubectl config delete-cluster "gke_${PROJECT_ID}_${REGION}_${CLUSTER}" >/dev/null 2>&1 || true
rm -f "$SUFFIX_FILE" "$ROOT/.last-image"

if [ "$PURGE" = 1 ]; then
  log "4/4 Purging state bucket"
  gcloud storage rm -r "gs://$STATE_BUCKET" --quiet >/dev/null 2>&1 || true; ok "state bucket removed"
else log "4/4 Kept state bucket gs://$STATE_BUCKET (a few KB; --purge removes it)"; fi

log "Anything billable left?"
echo "  GKE clusters:    $(gcloud container clusters list --project "$PROJECT_ID" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
echo "  Forwarding rules: $(gcloud compute forwarding-rules list --project "$PROJECT_ID" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
echo "  Static IPs:      $(gcloud compute addresses list --global --project "$PROJECT_ID" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
echo "  Cloud NAT/Router: $(gcloud compute routers list --project "$PROJECT_ID" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
log "DONE"
