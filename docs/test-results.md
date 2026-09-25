# Live test results

Run against project `claude-code-507112` · cluster `platform-eu` · 2026-09-25T22:32Z

**22 passed, 4 failed**

| | Check |
|---|---|
| ✅ | Autopilot cluster |
| ✅ | Private nodes (no public node IPs) |
| ✅ | Workload Identity pool set |
| ✅ | Binary Authorization enforced (project policy) |
| ✅ | Gateway API enabled |
| ✅ | Managed Prometheus on |
| ✅ | Control plane not open to the world |
| ✅ | unsigned image (nginx from Docker Hub) is DENIED |
| ✅ | signed image (our build) is ADMITTED |
| ✅ | policy suite: 9 cases (deny/allow) |
| ✅ | server pod ready (team-b) |
| ✅ | client pod ready (team-a) |
| ✅ | client pod ready (team-b) |
| ✅ | team-a -> team-b service is BLOCKED (cross-tenant) |
| ❌ | team-b -> team-b service is ALLOWED (same namespace) |
| ❌ | team-a reads its bucket with NO key files (federated token) |
| ❌ | team-b is DENIED on team-a's bucket (403) |
| ✅ | normal request -> 200 |
| ✅ | SQL injection -> 403 |
| ✅ | XSS -> 403 |
| ✅ | staging path routed via same Gateway |
| ✅ | pipeline exists |
| ✅ | latest release's prod rollout SUCCEEDED |
| ✅ | prod serves the released version |
| ✅ | app RED metrics queryable via PromQL |
| ❌ | HPA scaled out (2 -> 2 replicas) |
