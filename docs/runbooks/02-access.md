# 02 · Access the cluster & Argo CD

## kubectl
```bash
gcloud container clusters get-credentials $CLUSTER --region $REGION --project $PROJECT
kubectl get nodes
```
The API server accepts only your IP (`/32`, set at `up.sh` time) plus Google Cloud public IPs ([ADR 0003](../adr/0003-control-plane-access.md)). **Your IP changed?** (`i/o timeout` / `context deadline exceeded`)
```bash
NEWIP=$(curl -s https://api.ipify.org)
gcloud container clusters update $CLUSTER --region $REGION --project $PROJECT \
  --enable-master-authorized-networks --master-authorized-networks "$NEWIP/32"
```
(Or simply re-run `./scripts/up.sh`; Terraform reconciles it. `gcpPublicCidrsAccessEnabled` must stay on for Cloud Deploy — if the gcloud command drops it, re-run `up.sh`.)

## Argo CD UI
```bash
kubectl -n argocd port-forward svc/argocd-server 8081:80 &
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
open http://localhost:8081        # user: admin
```
Nothing exposes Argo CD publicly.

## Expected
```
$ kubectl -n argocd get applications
NAME                   SYNC STATUS   HEALTH STATUS
platform-gateway       Synced        Healthy
platform-monitoring    Synced        Healthy
platform-namespaces    Synced        Healthy
platform-policies      Synced        Healthy
platform-tenants       Synced        Healthy
root                   Synced        Healthy
```
