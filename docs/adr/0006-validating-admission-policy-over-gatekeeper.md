# ADR 0006 — Native ValidatingAdmissionPolicy (CEL) rather than Gatekeeper/Kyverno

**Status:** accepted

## Decision
Policy-as-code is expressed as Kubernetes `ValidatingAdmissionPolicy` + `Binding` (CEL), scoped by a namespace label (`policy.platform/enforce=true`), `Deny + Audit`.

## Consequences
* Evaluated **inside the API server** — no webhook to keep highly available, no extra controller to patch, no admission latency from a network hop; nothing to break on Autopilot.
* **Testable in CI** against a real API server (`kind`), with negative tests that go red if a policy is removed (`tests/admission-policies.sh`).
* **Trade-off:** less expressive than Rego/Kyverno (no mutation or generation, limited cross-object lookups). Add Kyverno only if mutation/generation are needed; keep VAP for the deny rules.
* Complements, not replaces, Binary Authorization (which decides *what image*) and Pod Security `restricted` (which decides *how it runs*).
