#!/usr/bin/env bash
# Live proof that each platform control actually works. Every check prints PASS/FAIL and the
# script exits non-zero on any failure. Results are also written to docs/test-results.md.
#   RUN_LOAD=1 ./scripts/test.sh     also run the HPA autoscaling test (~3 min)
source "$(dirname "$0")/lib.sh"
need kubectl; need gcloud; need curl; need python3
cluster_credentials
CTX="$(kubectl config current-context)"
tf_init
GW_IP="$($TF output -raw gateway_ip)"
REPO="$($TF output -raw artifact_repo)"
IMG="${IMG:-$(cat "$ROOT/.last-image" 2>/dev/null || true)}"
[ -n "$IMG" ] || die "no signed image known: run up.sh first (or export IMG=<repo>/shop@sha256:...)"
BUCKET_A="$($TF output -raw team_a_bucket)"

PASS=0; FAIL=0; RESULTS=()
check() { # <name> <command...>   (command succeeds => PASS)
  local name="$1"; shift
  if "$@" >/tmp/check.out 2>&1; then PASS=$((PASS+1)); RESULTS+=("| ✅ | $name |"); printf '  \033[32mPASS\033[0m %s\n' "$name"
  else FAIL=$((FAIL+1)); RESULTS+=("| ❌ | $name |"); printf '  \033[31mFAIL\033[0m %s\n        %s\n' "$name" "$(head -c 400 /tmp/check.out)"; fi
}
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# A restricted-PSS-compliant, signed-image test pod that just sleeps.
pod_yaml() { # <name> <namespace> <serviceAccount>
  cat <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $2, labels: {team: $2, app: probe}}
spec:
  serviceAccountName: ${3:-default}
  automountServiceAccountToken: true
  securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $IMG
      command: [python, -c, "import time; time.sleep(3600)"]
      resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 100m, memory: 128Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
YAML
}
run_pod() { pod_yaml "$@" | kubectl apply -f - >/dev/null && kubectl -n "$2" wait --for=condition=Ready "pod/$1" --timeout=240s >/dev/null; }
py() { # <ns> <pod> <python code>  -> runs inside the pod
  kubectl -n "$1" exec "$2" -- python -c "$3"
}

section "1. Cluster posture (gcloud describe)"
CJ="$(gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT_ID" --format=json)"
jq_() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" <<<"$CJ"; }
check "Autopilot cluster"                               test "$(jq_ "d['autopilot']['enabled']")" = True
check "Private nodes (no public node IPs)"              test "$(jq_ "d['privateClusterConfig']['enablePrivateNodes']")" = True
check "Workload Identity pool set"                      test "$(jq_ "d['workloadIdentityConfig']['workloadPool']")" = "$PROJECT_ID.svc.id.goog"
check "Binary Authorization enforced (project policy)"  test "$(jq_ "d['binaryAuthorization']['evaluationMode']")" = PROJECT_SINGLETON_POLICY_ENFORCE
check "Gateway API enabled"                             test "$(jq_ "d['networkConfig']['gatewayApiConfig']['channel']")" = CHANNEL_STANDARD
check "Managed Prometheus on"                           test "$(jq_ "d['monitoringConfig']['managedPrometheusConfig']['enabled']")" = True
check "Control plane not open to the world"             python3 -c "
import json,sys; d=json.loads(sys.argv[1]); c=[x['cidrBlock'] for x in d['masterAuthorizedNetworksConfig']['cidrBlocks']]
sys.exit(1 if '0.0.0.0/0' in c else 0)" "$CJ"

section "2. Supply chain: only pipeline-signed images run (Binary Authorization)"
unsigned() {
  pod_yaml unsigned team-a reader | sed "s|image: $IMG|image: docker.io/library/nginx:1.27.3|; /command:/d" | kubectl apply -f - >/tmp/unsigned.out 2>&1
  cat /tmp/unsigned.out; grep -qiE "binary authorization|denied by" /tmp/unsigned.out
}
check "unsigned image (nginx from Docker Hub) is DENIED"  unsigned
check "signed image (our build) is ADMITTED"               run_pod signed team-a reader
kubectl -n team-a delete pod unsigned signed --ignore-not-found --wait=false >/dev/null 2>&1

section "3. Admission policy-as-code (ValidatingAdmissionPolicy)"
check "policy suite: 9 cases (deny/allow)"  "$ROOT/tests/admission-policies.sh" "$CTX" team-a

section "4. Zero-trust networking (NetworkPolicy, default-deny)"
kubectl -n team-b apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata: {name: echo, namespace: team-b}
spec: {selector: {app: echo}, ports: [{port: 80, targetPort: 8080}]}
YAML
kubectl -n team-b delete pod server --ignore-not-found --wait=true >/dev/null 2>&1
# the shop image contains the app at /srv, so the server is just the app; label it app=echo for the Service
pod_yaml server team-b reader | sed 's|app: probe|app: echo|; s|command:.*|command: [python, -m, uvicorn, main:app, --host, 0.0.0.0, --port, "8080"]|' | kubectl apply -f - >/dev/null
check "server pod ready (team-b)"          kubectl -n team-b wait --for=condition=Ready pod/server --timeout=240s
check "client pod ready (team-a)"          run_pod client-a team-a reader
check "client pod ready (team-b)"          run_pod client-b team-b reader
SVC_IP="$(kubectl -n team-b get svc echo -o jsonpath='{.spec.clusterIP}')"; export SVC_IP
export GET_IP="import urllib.request,sys
try:
    r=urllib.request.urlopen('http://$SVC_IP/healthz',timeout=6); print('HTTP',r.status)
except Exception as e: print('ERR',type(e).__name__,e); sys.exit(3)"
GET_NAME='import urllib.request,sys
try:
    r=urllib.request.urlopen("http://echo.team-b.svc.cluster.local/healthz",timeout=6); print("HTTP",r.status)
except Exception as e: print("ERR",type(e).__name__,e); sys.exit(3)'
check "DNS works from a locked-down tenant pod (NodeLocal DNSCache allowed)" kubectl -n team-a exec client-a -- python -c "import socket; print(socket.gethostbyname('echo.team-b.svc.cluster.local'))"
# Prove isolation by IP so DNS cannot be the reason: the connection must TIME OUT (dropped by policy),
# not be refused/unresolvable, and the same request from inside team-b must succeed.
check "team-a -> team-b service IP is DROPPED by NetworkPolicy (timeout)" bash -c "kubectl -n team-a exec client-a -- python -c \"\$GET_IP\" 2>&1 | grep -qi 'timed out'"
check "team-b -> team-b service is ALLOWED (same namespace, by name)"      kubectl -n team-b exec client-b -- python -c "$GET_NAME"

section "5. Workload Identity: keyless access, per-tenant IAM"
TOK='import urllib.request,json
def tok():
    q=urllib.request.Request("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",headers={"Metadata-Flavor":"Google"})
    return json.load(urllib.request.urlopen(q,timeout=6))["access_token"]
'
READ="$TOK
import sys
try:
    r=urllib.request.Request('https://storage.googleapis.com/storage/v1/b/$BUCKET_A/o/hello.txt?alt=media',headers={'Authorization':'Bearer '+tok()})
    print(urllib.request.urlopen(r,timeout=8).read().decode().strip())
except urllib.error.HTTPError as e: print('HTTP',e.code); sys.exit(4)"
check "team-a reads its bucket with NO key files (federated token)" kubectl -n team-a exec client-a -- python -c "$READ"
check "team-b is DENIED on team-a's bucket (403)"                    bash -c "kubectl -n team-b exec client-b -- python -c \"$READ\" 2>&1 | grep -q 'HTTP 403'"

section "6. Edge: Cloud Armor WAF on the global external ALB"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check "normal request -> 200"                      test "$(code "http://$GW_IP/api/products")" = 200
check "SQL injection -> 403"                       test "$(code -G "http://$GW_IP/api/products" --data-urlencode "id=1' OR '1'='1")" = 403
check "XSS -> 403"                                 test "$(code -G "http://$GW_IP/" --data-urlencode 'q=<script>alert(1)</script>')" = 403
check "staging path routed via same Gateway"       test "$(code "http://$GW_IP/staging/healthz")" = 200

section "7. Progressive delivery (Cloud Deploy)"
check "pipeline exists"                            gcloud deploy delivery-pipelines describe shop --region "$REGION" --project "$PROJECT_ID"
LATEST_REL="$(gcloud deploy releases list --delivery-pipeline shop --region "$REGION" --project "$PROJECT_ID" --limit 1 --sort-by=~createTime --format='value(name.basename())')"
check "latest release's prod rollout SUCCEEDED"    bash -c "gcloud deploy rollouts list --delivery-pipeline shop --release $LATEST_REL --region $REGION --project $PROJECT_ID --format='value(name.basename(),state)' | grep -- '-to-prod-' | grep -q SUCCEEDED"
check "prod serves the released version"           bash -c "curl -s http://$GW_IP/version | grep -q '\"version\":\"v'"

section "8. Observability: Managed Prometheus -> Cloud Monitoring (PromQL)"
promq() { curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "x-goog-user-project: $PROJECT_ID" \
  "https://monitoring.googleapis.com/v1/projects/$PROJECT_ID/location/global/prometheus/api/v1/query" --data-urlencode "query=$1"; }
for _ in $(seq 1 20); do curl -s "http://$GW_IP/api/products" >/dev/null; sleep 1; done
for _ in $(seq 1 12); do promq 'sum(http_requests_total{namespace="shop-prod"})' | grep -q '"value"' && break; sleep 15; done
check "app RED metrics queryable via PromQL"       bash -c "$(declare -f promq); PROJECT_ID=$PROJECT_ID; promq 'sum(http_requests_total{namespace=\"shop-prod\"})' | grep -q '\"value\"'"

if [ "${RUN_LOAD:-0}" = 1 ]; then
  section "9. Autoscaling: HPA scales shop-staging under CPU load"
  BEFORE="$(kubectl -n shop-staging get hpa shop -o jsonpath='{.status.currentReplicas}')"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: loadgen, namespace: shop-staging, labels: {team: shop, app: loadgen}}
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
  restartPolicy: Never
  containers:
    - name: c
      image: $IMG
      command: [python, -c]
      args:
        - |
          import threading, time, urllib.request
          end = time.time() + 150
          def work():
              while time.time() < end:
                  try:
                      urllib.request.urlopen(urllib.request.Request("http://shop/api/checkout?work=1500000", method="POST"), timeout=30).read()
                  except Exception:
                      pass
          for _ in range(12):
              threading.Thread(target=work).start()
      resources: {requests: {cpu: 250m, memory: 128Mi}, limits: {cpu: 250m, memory: 128Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
YAML
  echo "  load running (150s), watching HPA…"; PEAK="$BEFORE"
  for _ in $(seq 1 16); do sleep 10; R="$(kubectl -n shop-staging get hpa shop -o jsonpath='{.status.currentReplicas}')"; [ "${R:-0}" -gt "${PEAK:-0}" ] && PEAK="$R"; done
  kubectl -n shop-staging delete pod loadgen --ignore-not-found --wait=false >/dev/null 2>&1
  check "HPA scaled out ($BEFORE -> $PEAK replicas)" test "${PEAK:-0}" -gt "${BEFORE:-0}"
fi

kubectl -n team-a delete pod client-a --ignore-not-found --wait=false >/dev/null 2>&1
kubectl -n team-b delete pod client-b server --ignore-not-found --wait=false >/dev/null 2>&1
kubectl -n team-b delete service echo --ignore-not-found >/dev/null 2>&1

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
{ echo "# Live test results"; echo; echo "Run against project \`$PROJECT_ID\` · cluster \`$CLUSTER\` · $(date -u +%Y-%m-%dT%H:%MZ)"; echo; echo "**$PASS passed, $FAIL failed**"; echo; echo "| | Check |"; echo "|---|---|"; printf '%s\n' "${RESULTS[@]}"; } > "$ROOT/docs/test-results.md"
[ "$FAIL" -eq 0 ]
