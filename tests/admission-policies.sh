#!/usr/bin/env bash
# Behavioural test for the ValidatingAdmissionPolicies. Runs against ANY cluster (kind in CI,
# GKE in scripts/test.sh): each case states the expected verdict and the script fails on a mismatch.
#   tests/admission-policies.sh [kube-context] [namespace]
set -uo pipefail
CTX="${1:-$(kubectl config current-context)}"; NS="${2:-team-a}"
K="kubectl --context $CTX"; fail=0

pod() { # name labels image
  cat <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $NS, labels: {$2}}
spec:
  containers:
    - name: c
      image: $3
      resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 50m, memory: 64Mi}}
      securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, runAsUser: 10001, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}
YAML
}

# verdict <expect: DENY|ALLOW> <description> <command...>
# DENY  = rejected by a ValidatingAdmissionPolicy (the message names it).
# ALLOW = the policies let it through: it was created, OR it was stopped later by Binary
#         Authorization (on GKE an unsigned demo image is denied there, which is not a VAP verdict).
verdict() {
  local expect="$1" desc="$2"; shift 2
  local out; out="$("$@" 2>&1)"; local rc=$?
  local got="ERROR"
  if grep -q "ValidatingAdmissionPolicy" <<<"$out" && [ $rc -ne 0 ]; then got="DENY"
  elif [ $rc -eq 0 ] || grep -qiE "binary authorization|binaryauthorization" <<<"$out"; then got="ALLOW"; fi
  if [ "$got" = "$expect" ]; then printf '  \033[32mPASS\033[0m %-5s %s\n' "$expect" "$desc"
  else printf '  \033[31mFAIL\033[0m want %s got %s: %s\n        %s\n' "$expect" "$got" "$desc" "$(head -c 300 <<<"$out")"; fail=1; fi
}
apply_pod() { pod "$@" | $K apply -f -; }
suffix="$RANDOM"

echo "Admission policy tests on context '$CTX', namespace '$NS'"
verdict DENY  "image :latest"                       apply_pod "t-latest-$suffix"  'team: a' 'nginx:latest'
verdict DENY  "image without a tag"                 apply_pod "t-notag-$suffix"   'team: a' 'nginx'
verdict DENY  "pod without team label"              apply_pod "t-nolabel-$suffix" 'app: x'  'nginx:1.27'
verdict DENY  "registry:port/image without a tag"   apply_pod "t-port-$suffix"    'team: a' 'localhost:5000/app'
verdict DENY  "Service type LoadBalancer"           $K -n "$NS" create service loadbalancer "lb-$suffix" --tcp=80:80
verdict ALLOW "compliant pod (tag + team label)"    apply_pod "t-ok-$suffix"      'team: a' 'nginx:1.27'
verdict ALLOW "digest-pinned image"                 apply_pod "t-dig-$suffix"     'team: a' 'registry.k8s.io/pause@sha256:a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9'
verdict ALLOW "registry:port/image:tag"             apply_pod "t-portok-$suffix"  'team: a' 'localhost:5000/app:1.0'
verdict ALLOW "Service type ClusterIP"              $K -n "$NS" create service clusterip "ok-$suffix" --tcp=80:80

$K -n "$NS" delete pod -l 'team=a' --ignore-not-found --wait=false >/dev/null 2>&1
$K -n "$NS" delete service "ok-$suffix" --ignore-not-found >/dev/null 2>&1
[ $fail -eq 0 ] && echo "all admission-policy checks passed" || { echo "FAILED"; exit 1; }
