# 01 · Build & teardown

## Build (one command, idempotent)
```bash
gcloud config set project <project>      # billing linked
./scripts/up.sh                          # ~25-35 min end to end
./scripts/up.sh --plan                   # preview only, changes nothing
```
What it does, in order: (1) Terraform state bucket → (2) infra: VPC/NAT, Autopilot cluster, KMS + Binary Authorization, Artifact Registry, Cloud Armor, Cloud Deploy pipeline, alerts, budget, WIF (~97 resources) → (3) cluster credentials → (4) Argo CD via Helm + the platform app-of-apps → (5) Cloud Build: build, vulnerability scan, sign → (6) Cloud Deploy release to staging → (7) promote to prod: approval, canary 25/50/100 → (8) wait for the public endpoint → (9) live test suite.

*Verified live (2026-09-25/26):* `up.sh` built the full stack and `scripts/test.sh` passed 28/28; before that it was validated with `terraform plan` (97 resources), schema validation (54 manifests) and the admission suite on a real API server (see [06](06-tenancy-and-policy.md)).

### Prerequisites
`gcloud`, `terraform >= 1.9`, `kubectl`, `helm`, `curl`, `python3`, `gke-gcloud-auth-plugin` (`gcloud components install gke-gcloud-auth-plugin`). Argo CD syncs from **GitHub**, so push your commits before `up.sh` (it warns if you haven't).

## Teardown (one command)
```bash
./scripts/down.sh            # everything this repo created
./scripts/down.sh --purge    # ...and the Terraform state bucket
```
Order matters and is handled: Argo CD stopped → Gateway/routes/namespaces deleted (this removes the **load balancer, NEGs and firewall rules created by the Gateway controller**, which Terraform doesn't own and which would block VPC/Cloud Armor deletion) → Cloud Deploy pipeline force-deleted → `terraform destroy` → billable-leftover check.

### Teardown — *Captured* (live, `./scripts/down.sh`)
```
==> 1/4 Removing Kubernetes-created cloud resources (LB, NEGs, firewall rules)
  waiting for load balancer + NEG cleanup
✔ Kubernetes-created cloud resources gone
==> 2/4 Cloud Deploy (releases/rollouts block pipeline deletion unless forced)
✔ pipeline removed
==> 3/4 Terraform destroy
Destroy complete! Resources: 94 destroyed.
✔ platform destroyed
==> Anything billable left?
  GKE clusters:     0
  Forwarding rules: 0
  Static IPs:       0
  Cloud NAT/Router: 0
```
Independently verified afterwards with real listings: no clusters, forwarding rules, routers, backend services, URL maps, Cloud Armor policies, proxies, NEGs or health checks remained. (Tip: `gcloud ... list | wc -l` prints `1` for an empty list because gcloud emits a blank line — use `--format='value(name)'` and test for empty output.)

Leftovers that cost ~nothing and are intentional: the KMS key ring (GCP never deletes key rings; versions are scheduled for destruction) and, with no `--purge`, a few KB of Terraform state.

**Names that cannot be reused for 30 days** (KMS key ring, WIF pool) get a per-deployment suffix (`.deploy-suffix`, gitignored) so a rebuild never collides.
