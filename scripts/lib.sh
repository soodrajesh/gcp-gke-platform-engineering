#!/usr/bin/env bash
# Shared helpers for up.sh / down.sh / test.sh. Sourced, not executed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1${2:+ ($2)}"; }

[ -f "$ROOT/deploy.env" ] && set -a && . "$ROOT/deploy.env" && set +a

# gke-gcloud-auth-plugin ships with gcloud but is often not on PATH
SDK_BIN="$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null)/bin"
[ -d "$SDK_BIN" ] && export PATH="$SDK_BIN:$PATH"
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-europe-west1}"
CLUSTER="${CLUSTER:-platform-eu}"
ADMIN_EMAIL="${ADMIN_EMAIL:-$(gcloud config get-value account 2>/dev/null)}"
ALERT_EMAIL="${ALERT_EMAIL:-$ADMIN_EMAIL}"
GITHUB_REPO="${GITHUB_REPO:-soodrajesh/gcp-gke-platform-engineering}"
BUDGET_AMOUNT="${BUDGET_AMOUNT:-25}"
[ -n "$PROJECT_ID" ] || die "no project: set PROJECT_ID in deploy.env or 'gcloud config set project'"
BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:-$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingAccountName)' 2>/dev/null | sed 's|billingAccounts/||')}"
[ -n "$BILLING_ACCOUNT_ID" ] || die "project has no billing account linked"

TF="terraform -chdir=$ROOT/terraform"
STATE_BUCKET="${PROJECT_ID}-tfstate"
SUFFIX_FILE="$ROOT/.deploy-suffix"

my_ip() { curl -fsS https://api.ipify.org 2>/dev/null || curl -fsS https://ifconfig.me 2>/dev/null; }

export TF_VAR_project_id="$PROJECT_ID" TF_VAR_region="$REGION" TF_VAR_cluster_name="$CLUSTER" \
       TF_VAR_billing_account_id="$BILLING_ACCOUNT_ID" TF_VAR_alert_email="$ALERT_EMAIL" \
       TF_VAR_admin_email="$ADMIN_EMAIL" TF_VAR_github_repo="$GITHUB_REPO" TF_VAR_budget_amount="$BUDGET_AMOUNT"

tf_init() { $TF init -input=false -backend-config="bucket=$STATE_BUCKET" >/dev/null; }

resolve_suffix() {
  if [ ! -f "$SUFFIX_FILE" ]; then
    existing="$($TF state list 2>/dev/null || true)"   # capture first: grep -q would SIGPIPE terraform
    if grep -q '^module.binauthz\.' <<<"$existing"; then : > "$SUFFIX_FILE"
    else printf -- '-%s' "$(date +%y%m%d%H%M)" > "$SUFFIX_FILE"; fi
  fi
  export TF_VAR_resource_suffix="$(cat "$SUFFIX_FILE")"
}

set_authorized_cidr() {
  local ip; ip="$(my_ip || true)"
  [ -n "$ip" ] || die "could not determine your public IP (needed to allow kubectl access)"
  export TF_VAR_authorized_cidr="$ip/32"
}

cluster_credentials() {
  gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1
}

# kubectl wait helper with a readable timeout message
wait_for() { # <description> <timeout-seconds> <command...>
  local desc="$1" timeout="$2"; shift 2
  local end=$(( $(date +%s) + timeout ))
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$end" ] || die "timed out after ${timeout}s waiting for: $desc"
    sleep 5
  done
  ok "$desc"
}
