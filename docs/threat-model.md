# Threat model

STRIDE over the platform's trust boundaries, mapped to controls **and to the test that proves each one** (`scripts/test.sh`).

| Threat | Scenario | Control | Proof |
|---|---|---|---|
| **S**poofing | Stolen CI credentials deploy to prod | Keyless OIDC (WIF); deploy identity bound to protected `prod` environment; prod rollout needs human approval | `docs/runbooks/05` |
| **T**ampering | Unsigned/altered image runs | Binary Authorization: only KMS-signed digests; immutable tags; digest-pinned releases | test §2 |
| **T**ampering | Drift / hand-edited cluster config | Argo CD self-heal + prune on platform layer | runbook 03 |
| **R**epudiation | "Who approved that release?" | Cloud Deploy approvals + Cloud Audit Logs; BinAuth denials audit-logged | runbook 05 |
| **I**nformation disclosure | Tenant reads another tenant's data | NetworkPolicy default-deny; per-tenant Workload Identity principal with resource-level IAM | test §4, §5 |
| **I**nformation disclosure | Long-lived cloud keys leak | No keys anywhere: Workload Identity / WIF | test §5 |
| **D**enial of service | Volumetric / abusive traffic | Cloud Armor throttle + WAF rules; ResourceQuota; PDBs; HPA (staging) | test §6, §9 |
| **D**enial of service | Bad release | Canary limits blast radius; 5xx-ratio alert; one-command rollback | `demo-bad-release.sh` |
| **E**levation of privilege | Privileged pod / host access | Autopilot + Pod Security `restricted`; non-root, read-only rootfs, drop ALL caps | admission tests |
| **E**levation of privilege | Bypass WAF with own LoadBalancer | Admission policy denies `LoadBalancer`/`NodePort` | test §3 |

## Known gaps (deliberate, documented)
* Control-plane endpoint is public-with-allow-list (ADR 0003).
* No TLS on the demo endpoint (ADR 0007).
* Binary Authorization allow-list for upstream add-ons is a reviewed hole (ADR 0004); provenance and scan attestations are not yet required.
* Soft multi-tenancy (ADR 0008).
* No VPC Service Controls perimeter, no Cloud Service Mesh mTLS.
