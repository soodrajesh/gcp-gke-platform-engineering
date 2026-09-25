# 03 · Change the platform via GitOps

**Rule:** the platform layer is changed by pull request, never by `kubectl apply`. Argo CD has `selfHeal: true`, so manual edits are reverted within minutes.

## Add a tenant namespace
1. Add a `Namespace` (+ `ResourceQuota`, `LimitRange`) to `gitops/platform/namespaces/namespaces.yaml` and a matching pair of `NetworkPolicy` objects to `networkpolicies.yaml` — copy `team-a`.
2. `kubeconform` + kind policy tests run in CI. Merge.
3. Argo syncs (wave 0). Verify:
```bash
kubectl -n argocd get application platform-namespaces
kubectl get ns team-c --show-labels
kubectl -n team-c get resourcequota,limitrange,networkpolicy
```

## Prove drift is healed
```bash
kubectl -n team-a delete networkpolicy default-deny       # simulate a hand edit
sleep 90; kubectl -n team-a get networkpolicy default-deny  # Argo CD has put it back
```
*Expected:* the policy reappears (Argo event `OutOfSync → Synced`). Audit who tried: Cloud Logging → `protoPayload.methodName="io.k8s.networking.v1.networkpolicies.delete"`.

## Roll back a bad platform change
`git revert <sha>` and merge; Argo reconciles to the previous state. For an emergency, `kubectl -n argocd patch application platform-<x> --type merge -p '{"spec":{"syncPolicy":null}}'` pauses auto-sync (re-enable afterwards).
