# Live test results

Run against project `claude-code-507112` · cluster `platform-eu` · 2026-09-25T23:24Z

**28 passed, 0 failed**

| | Check |
|---|---|
| ✅ | Autopilot cluster |
| ✅ | Private nodes (no public node IPs) |
| ✅ | Workload Identity pool set |
| ✅ | Binary Authorization enforced (project policy) |
| ✅ | Gateway API enabled |
| ✅ | Managed Prometheus on |
| ✅ | Control plane not open to the world |
| ✅ | unsigned image pinned by digest is DENIED: 'No attestations found...' |
| ✅ | tag-referenced image is DENIED (Binary Authorization requires digests) |
| ✅ | signed image (our build) is ADMITTED |
| ✅ | policy suite: 9 cases (deny/allow) |
| ✅ | server pod ready (team-b) |
| ✅ | client pod ready (team-a) |
| ✅ | client pod ready (team-b) |
| ✅ | DNS works from a locked-down tenant pod (NodeLocal DNSCache allowed) |
| ✅ | team-a -> team-b service IP is DROPPED by NetworkPolicy (timeout) |
| ✅ | team-b -> team-b service is ALLOWED (same namespace, by name) |
| ✅ | team-a reads its bucket with NO key files (federated token) |
| ✅ | team-b is DENIED on team-a's bucket (403 from Google, no grant) |
| ✅ | normal request -> 200 |
| ✅ | SQL injection -> 403 |
| ✅ | XSS -> 403 |
| ✅ | staging path routed via same Gateway |
| ✅ | pipeline exists |
| ✅ | current prod rollout (newest non-cancelled) SUCCEEDED |
| ✅ | prod serves the released version |
| ✅ | app RED metrics queryable via PromQL |
| ✅ | HPA scaled out (4 -> 9 replicas) |
