# 06 · Onboard a tenant & policy tests

## Policy behaviour — *Captured* (real Kubernetes API server, kind v1.37, this repo's manifests)
```
$ tests/admission-policies.sh kind-vap-test team-a
Admission policy tests on context 'kind-vap-test', namespace 'team-a'
  PASS DENY  image :latest
  PASS DENY  image without a tag
  PASS DENY  pod without team label
  PASS DENY  registry:port/image without a tag
  PASS DENY  Service type LoadBalancer
  PASS ALLOW compliant pod (tag + team label)
  PASS ALLOW digest-pinned image
  PASS ALLOW registry:port/image:tag
  PASS ALLOW Service type ClusterIP
all admission-policy checks passed
```
And the suite is **not vacuous**: with the `disallow-latest-tag` binding deleted it prints `FAIL want DENY got ALLOW: image :latest` (and two more) and exits 1.

Example rejection message a developer sees:
```
The pods "t1" is invalid: : ValidatingAdmissionPolicy 'disallow-latest-tag' with binding
'disallow-latest-tag' denied request: images must be pinned by digest or an explicit non-'latest' tag
```

## "A policy denied my deploy"
| Message | Meaning | Fix |
|---|---|---|
| `disallow-latest-tag` | `:latest` or no tag | Pin by digest or explicit tag |
| `require-team-label` | Pod has no `team` label | Add `team: <name>` to the pod template (feeds cost attribution) |
| `deny-public-services` | `LoadBalancer`/`NodePort` | Use `ClusterIP` + an `HTTPRoute` on the shared Gateway |
| `exceeded quota` | `ResourceQuota` | Right-size requests or raise the quota via PR |
| `violates PodSecurity "restricted"` | Non-root/rootfs/caps rules | `runAsNonRoot`, drop `ALL`, `seccompProfile: RuntimeDefault` |

## Add or change a policy
Edit `gitops/platform/policies/policies.yaml`; add a case to `tests/admission-policies.sh` (**both** a deny and an allow); CI runs it on kind before merge.

## Onboard tenant "team-c"
See [03](03-gitops-changes.md); for cloud access, grant the tenant's Workload Identity principal only what it needs in Terraform:
```hcl
member = "principal://iam.googleapis.com/projects/<NUM>/locations/global/workloadIdentityPools/<PROJECT>.svc.id.goog/subject/ns/team-c/sa/reader"
```
No Google service account, no key file. Verify (as scripts/test.sh does): team-c pod gets a token from the metadata server and reads only its bucket; other tenants get `403`.
