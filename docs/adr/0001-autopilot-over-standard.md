# ADR 0001 — GKE Autopilot rather than Standard

**Status:** accepted

## Context
The platform's value is in the layers above the nodes (identity, policy, delivery, observability). Node management is undifferentiated toil and a common source of drift and CVE exposure.

## Decision
GKE **Autopilot**, regional, REGULAR release channel, private nodes, custom least-privilege node service account.

## Consequences
* Google manages nodes, bin-packing, upgrades, hardening; Shielded Nodes, Workload Identity and Dataplane V2 (NetworkPolicy) come by default. Billing is per pod request, not per idle node — cost tracks workload.
* Guardrails to design around: no privileged pods/host access, resource requests are enforced/mutated, some webhooks are restricted. This platform stays within them (and its admission policies use native CEL, not a webhook).
* **Trade-off:** no custom node images, GPUs need specific compute classes, and DaemonSet-heavy tooling is constrained. If those become requirements, move workloads to a Standard cluster/node pool; the Terraform, GitOps and delivery layers are unchanged.
