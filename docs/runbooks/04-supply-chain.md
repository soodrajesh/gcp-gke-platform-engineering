# 04 · Supply chain: build, sign, verify

## Build + scan + sign
```bash
./scripts/up.sh          # does it as step 5, or manually:
gcloud builds submit --config cloudbuild.yaml --region $REGION --service-account projects/$PROJECT/serviceAccounts/plat-build@$PROJECT.iam.gserviceaccount.com \
  --gcs-source-staging-dir gs://$PROJECT-gke-build-staging/src \
  --substitutions _REPO=<repo>,_TAG=v1,_KMS_KEYRING=<keyring>,_ATTESTOR=built-by-pipeline .
```
Steps: `build → push → scan → attest`. Set `_BLOCK_ON_CRITICAL=true` to fail the build on any CRITICAL vulnerability.

## Verify an attestation exists for a digest
```bash
IMG=$(cat .last-image)
gcloud container binauthz attestations list --attestor=built-by-pipeline --attestor-project=$PROJECT --artifact-url=$IMG
```
*Expected:* one attestation, signed by `.../cryptoKeyVersions/1`.

## "My pod is denied" — Binary Authorization — *Captured* (live GKE Autopilot)
An **unsigned image pinned by digest** (denied because no trusted attestation exists):
```
Error from server (VIOLATES_POLICY): error when creating "STDIN": admission webhook "imagepolicywebhook.image-policy.k8s.io"
denied the request: Image docker.io/library/nginx@sha256:bc2f6a7c...fcef denied by Binary Authorization default admission rule.
Image docker.io/library/nginx@sha256:bc2f6a7c...fcef denied by attestor projects/claude-code-507112/attestors/built-by-pipeline:
No attestations found that were valid and signed by a key trusted by the attestor
```
An image referenced by **tag** is denied outright, even if it is in our registry (Binary Authorization needs a digest to look up attestations):
```
... denied by attestor projects/claude-code-507112/attestors/built-by-pipeline: Expected digest with sha256 scheme, but got tag or malformed digest
```

| Cause | Fix |
|---|---|
| Image not built by the pipeline | Build it with Cloud Build ([above]) |
| Image referenced by **tag** | Always deploy by digest: `--images shop=<repo>/shop@sha256:...` (Cloud Deploy releases do) |
| Upstream add-on (Argo, Redis) | Add its registry pattern to `var.admission_allowlist` in Terraform — reviewed, minimal |
| Genuine emergency | Pod annotation `alpha.image-policy.k8s.io/break-glass: "true"` (audit-logged); follow up with a review |

Find who was blocked and why:
```bash
gcloud logging read 'protoPayload.serviceName="binaryauthorization.googleapis.com"' --project $PROJECT --limit 5 --format='value(timestamp,protoPayload.status.message)'
```

## Rotate the signing key
Create a new key **version**, add it to the attestor's public keys, then disable the old one after all in-flight images are re-attested. Never delete a version that signed a currently running image.
