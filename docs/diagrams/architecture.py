#!/usr/bin/env python3
"""Generates docs/img/architecture.svg (PNG via docs/diagrams/render.py).

    python3 docs/diagrams/architecture.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from archlib import Diagram  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "img", "architecture.svg")

W, H = 1700, 1640
d = Diagram(W, H, "GKE Platform Engineering on Google Cloud",
            "Autopilot · Binary Authorization · Cloud Deploy canary · Argo CD · Gateway API + Cloud Armor · policy-as-code · Terraform")

# ── outer boundary ──────────────────────────────────────────────────────────────────────────────
d.group(190, 96, 1480, 1214, "Google Cloud project  ·  region europe-west1", "#1a73e8", dash=False, fill="#f8faff", label_w=330)

# ── REQUEST path: edge (outside the VPC) ─────────────────────────────────────────────────────────
d.node("users", 96, 250, "Users", "user", "actor", "internet")
d.node("armor", 270, 250, "Cloud Armor", "wall", "security", "OWASP SQLi/XSS deny\n120 req/min/IP")
d.node("alb", 440, 250, "Global external\nALB", "lb", "network", "Gateway API\nstatic IP")

# ── VPC ──────────────────────────────────────────────────────────────────────────────────────────
d.group(540, 120, 900, 700, "VPC platform-vpc  ·  private nodes  ·  Cloud NAT", "#8e44ad", dash=True, fill="#faf5fd", label_w=330)
d.small("nat", 1390, 792, "", "nat", "network")
d.text(1070, 796, "Cloud NAT: controlled egress · nodes have no public IPs · API server: operator /32 + Google IPs", 11.5, "#5f6368", "400", "middle")

# ── GKE cluster ──────────────────────────────────────────────────────────────────────────────────
d.group(562, 152, 856, 612, "GKE Autopilot · Workload Identity · Dataplane V2 · REGULAR channel", "#1a73e8", dash=False, fill="#ffffff", label_w=470)

# admission gates
d.group(582, 190, 816, 118, "ADMISSION · three independent gates on every pod", "#d93025", dash=True, fill="#fff8f7", label_w=390)
d.small("pss", 690, 246, "Pod Security\nrestricted", "policy", "security")
d.small("vap", 990, 246, "ValidatingAdmission\nPolicy (CEL)", "policy", "security")
d.small("bin", 1290, 246, "Binary Authorization\nsigned digests only", "shield", "security")
d.edge("pss", "vap", "h", half_a=22, half_b=22, color="#d93025", label="how it runs → org rules")
d.edge("vap", "bin", "h", half_a=22, half_b=22, color="#d93025", label="→ what it is")

# namespaces
def ns(x, w, label, color):
    d.group(x, 336, w, 214, label, color, dash=False, fill="#fbfcff", label_w=len(label) * 6.4 + 24)

ns(582, 210, "shop-prod · canary", "#1e8e3e")
for i, x in enumerate((612, 660, 708)):
    d.small(f"pp{i}", x, 430, "", "pod", "compute")
d.small("pc", 756, 430, "", "pod", "ai")
d.text(686, 476, "stable ×3", 11.5, "#3c4043", "600", "middle")
d.text(756, 476, "canary", 11.5, "#b06000", "600", "middle")
d.text(687, 516, "one Service · one LB", 11, "#5f6368", "400", "middle")

ns(808, 190, "shop-staging · HPA", "#5f6368")
d.small("sp0", 850, 430, "", "pod", "compute")
d.small("sp1", 902, 430, "", "pod", "compute")
d.small("sp2", 954, 430, "", "pod", "compute")
d.text(902, 476, "2 → 9 pods on CPU", 11.5, "#3c4043", "600", "middle")
d.text(903, 516, "load test runs here", 11, "#5f6368", "400", "middle")

ns(1014, 180, "team-b", "#5f6368")
d.small("tb", 1104, 430, "", "pod", "compute")
d.text(1104, 476, "no bucket grant", 11.5, "#3c4043", "600", "middle")
d.text(1104, 516, "→ 403 from Google", 11, "#d93025", "400", "middle")

ns(1212, 186, "team-a · tenant", "#5f6368")
d.small("ta", 1305, 430, "", "pod", "compute")
d.text(1305, 476, "KSA reader", 11.5, "#3c4043", "600", "middle")
d.text(1305, 516, "bucket: objectViewer", 11, "#5f6368", "400", "middle")

# platform layer
d.group(582, 572, 816, 174, "PLATFORM LAYER  ·  reconciled from git by Argo CD (self-heal + prune)", "#5f6368", dash=True, fill="#f8f9fa", label_w=560)
d.node("argo", 680, 650, "Argo CD", "argo", "dev", "app-of-apps")
d.node("np", 880, 650, "NetworkPolicy", "wall", "network", "default-deny\nns-to-ns blocked")
d.node("quota", 1080, 650, "ResourceQuota", "policy", "compute", "+ LimitRange\nper tenant")
d.node("gmp", 1290, 650, "Managed\nPrometheus", "chart", "ops", "RED metrics\nPromQL")

# ── request-path edges ───────────────────────────────────────────────────────────────────────────
d.edge("users", "armor", "h", num=1, label="HTTP")
d.edge("armor", "alb", "h", num=2)
d.path([(470, 250), (520, 250), (520, 480), (582, 480)], num=3, label="NEG → pod IPs", lab_at=(520, 380))

# workload identity: team-a -> bucket outside the project's VPC
d.node("gcs", 1590, 430, "Cloud Storage", "bucket", "data", "team-a-data")
d.path([(1398, 430), (1560, 430)], num=4, label="federated token", lab_at=(1478, 430))
d.text(1590, 528, "No key files. IAM is", 11, "#5f6368", "400", "middle")
d.text(1590, 542, "granted directly to the", 11, "#5f6368", "400", "middle")
d.text(1590, 556, "Workload Identity principal", 11, "#5f6368", "400", "middle")
d.text(1590, 570, "ns/team-a/sa/reader", 11, "#3c4043", "700", "middle")

# ── DELIVERY path ────────────────────────────────────────────────────────────────────────────────
d.band(210, 870, 1440, 254, "DELIVERY PATH  ·  signed, progressive, keyless", "#5f6368", "#ffffff")
d.node("dev", 96, 985, "Developer", "user", "actor")
d.node("gh", 250, 985, "GitHub\n+ Actions CI", "git", "actor", "CI: lint · test ·\nkind policy tests")
d.node("wif", 470, 985, "Workload Identity\nFederation", "key", "security", "OIDC · no SA keys")
d.node("cb", 690, 985, "Cloud Build", "pipeline", "dev", "build · vuln scan\ndedicated SA · SLSA")
d.node("ar", 910, 985, "Artifact Registry", "registry", "dev", "immutable tags\ndigest-pinned")
d.node("cd", 1130, 985, "Cloud Deploy", "pipeline", "compute", "staging → approval →\ncanary 25 / 50 / 100 %")
d.small("kms", 690, 900, "", "key", "security")
d.text(720, 896, "Cloud KMS", 12.5, "#202124", "700")
d.text(720, 911, "asymmetric signing key", 11, "#5f6368")

d.edge("dev", "gh", "h", label="push / PR", color="#5f6368")
d.edge("gh", "wif", "h", num="A", label="OIDC token", color="#5f6368")
d.edge("wif", "cb", "h", num="B", color="#5f6368")
d.edge("cb", "ar", "h", num="C", label="push image", color="#5f6368")
d.edge("ar", "cd", "h", num="E", label="digest", color="#5f6368")
d.edge("cb", "kms", "v", num="D", color="#d93025", dash=True, half_b=22)
d.text(712, 942, "sign digest → attestation", 11, "#d93025", "600")
# deploy into the cluster; GitOps into the platform layer
d.path([(1130, 955), (1130, 850), (760, 850), (760, 764)], num="F", label="deploy as executor SA, then admission verifies the signature", lab_at=(945, 850), color="#1e8e3e")
d.path([(96, 955), (96, 850), (600, 850), (600, 650), (650, 650)], num="G", label="GitOps: Argo CD pulls gitops/platform from git", lab_at=(340, 850), color="#5f6368", dash=True)

# ── governance + operations ──────────────────────────────────────────────────────────────────────
d.band(210, 1146, 700, 150, "GOVERNANCE  ·  preventive controls, enforced by the platform", "#d93025", "#fff8f7")
d.node("g1", 300, 1206, "Binary Authorization", "shield", "security", "policy: signed only\nblock + audit log")
d.node("g2", 500, 1206, "Workload Identity", "key", "security", "IAM to ns/sa principal\nno service-account keys")
d.node("g3", 700, 1206, "Least-privilege IAM", "shield", "security", "node SA, build SA,\nexecutor SA, CI plan ≠ deploy")
d.band(930, 1146, 720, 150, "OPERATIONS  ·  SRE + FinOps", "#1e8e3e", "#f6fcf8")
d.node("o1", 1020, 1206, "Cloud Monitoring", "chart", "ops", "PromQL 5xx alert\ndashboard")
d.node("o2", 1200, 1206, "Cloud Monitoring\nuptime check", "globe", "ops", "external probe of prod")
d.node("o3", 1380, 1206, "Cloud Logging", "policy", "ops", "workload + audit logs")
d.node("o4", 1560, 1206, "Budget + cost\nallocation", "money", "ops", "alerts · spend by\nnamespace / label")

# ── legends ──────────────────────────────────────────────────────────────────────────────────────
d.legend(34, 1336, "Request path (numbered)", [
    ("1", "Client hits the reserved global IP; Cloud Armor evaluates OWASP SQLi/XSS rules + a per-IP throttle"),
    ("2", "Global external ALB (Gateway API) routes by path; tenants attach HTTPRoutes from their own namespace"),
    ("3", "Container-native load balancing sends traffic straight to pod IPs; a canary shares the same Service"),
    ("4", "Workload Identity: the team-a pod gets a federated token and reads only its own bucket, with no keys"),
], w=820)
d.legend(880, 1336, "Delivery path (lettered)", [
    ("A", "PR / push runs CI; the release job federates into GCP with a GitHub OIDC token (no keys)"),
    ("B", "Only the protected `prod` environment can assume the deploy identity"),
    ("C", "Cloud Build builds the image, pushes it and scans it for vulnerabilities"),
    ("D", "The image DIGEST is signed with a KMS-held key, creating a Binary Authorization attestation"),
    ("E", "Cloud Deploy releases the digest: staging automatically, prod after human approval"),
    ("F", "Prod rolls out as a canary; a rollback is itself an approved rollout"),
    ("G", "Argo CD reconciles the platform layer (namespaces, policies, gateway) from git"),
], w=790, color="#5f6368")
d.key(34, 1548)
d.text(34, 1616, "Boundaries: project (blue) · VPC (purple, dashed) · cluster (blue) · admission gates (red, dashed).", 11.5)

if __name__ == "__main__":
    d.save(OUT)
    print("wrote", os.path.abspath(OUT))
