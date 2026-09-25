# ADR 0004 — Only pipeline-signed images run: Binary Authorization with a KMS-held signing key

**Status:** accepted

## Decision
* Cloud Build builds, pushes, vulnerability-scans and then **signs the image digest** with an asymmetric key in Cloud KMS (the private key never leaves Google) creating an attestation for the `built-by-pipeline` attestor.
* The project's Binary Authorization policy is `REQUIRE_ATTESTATION` with `ENFORCED_BLOCK_AND_AUDIT_LOG`; Google system images are exempt via the global policy, and a short explicit allow-list covers upstream add-ons (Argo CD, Redis).
* Releases reference images **by digest**, never by mutable tag; Artifact Registry tags are immutable.

## Consequences
* An image pulled from Docker Hub — or built on a laptop — cannot run, even with cluster-admin. The rejection is audit-logged. `scripts/test.sh` proves it live.
* The build service account is the only identity able to sign (`signerVerifier` on the one key), so "built by our pipeline" is a meaningful claim.
* **Trade-off:** the allow-list is a deliberate hole; keep it minimal and reviewed. Break-glass: use the `--break-glass` annotation (audited) or add a pattern via Terraform.
* **Next step (not done):** verify SLSA provenance and require a vulnerability-scan attestation in the policy, not just a signature.
