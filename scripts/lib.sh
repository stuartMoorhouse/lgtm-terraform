#!/usr/bin/env bash
# Shared helpers. Source this file; do not execute it.
# Never enables xtrace; the Grafana admin password is held only in the GF_PASS
# shell variable (not exported) and passed to curl via a /dev/fd curl config,
# so it never appears in `ps` output, on disk, or in env.json.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
ENV_JSON="$ROOT_DIR/shared/env.json"
RESULTS_DIR="$ROOT_DIR/results"

export AWS_PROFILE="${AWS_PROFILE:-company}"
EXPECTED_ACCOUNT="461485115270"
NS_LGTM="lgtm"
NS_SHOP="astronomy-shop"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"; done
}

# ---- Terraform outputs ----------------------------------------------------
tf_out() { # tf_out <name>  -> raw value, empty string if missing/unset
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true
}

tf_out_req() {
  local v
  v="$(tf_out "$1")"
  [ -n "$v" ] || die "terraform output '$1' is empty. Has 'terraform apply' completed in $TF_DIR?"
  printf '%s' "$v"
}

# All S3 bucket names exposed by terraform outputs whose output name contains
# "bucket" (string, list or map values are all flattened).
tf_bucket_names() {
  terraform -chdir="$TF_DIR" output -json 2>/dev/null \
    | jq -r 'to_entries[] | select(.key|test("bucket")) | .value.value | [.. | strings] | .[]' 2>/dev/null \
    | sort -u || true
}

# ---- AWS / kube -------------------------------------------------------------
check_account() {
  local acct
  acct="$(aws sts get-caller-identity --profile company --query Account --output text 2>&1)" \
    || die "aws sts get-caller-identity failed (profile company): $acct"
  [ "$acct" = "$EXPECTED_ACCOUNT" ] || die "wrong AWS account $acct, expected $EXPECTED_ACCOUNT"
  printf '%s' "$acct"
}

setup_kubeconfig() {
  local cmd
  cmd="$(tf_out_req kubeconfig_command)"
  log "Updating kubeconfig"
  bash -c "$cmd" >/dev/null || die "kubeconfig command failed"
}

kube_ok() { kubectl get ns "$NS_LGTM" >/dev/null 2>&1; }

# Prints "ns/pod" for every pod that is not Succeeded and not Ready.
pods_not_ready() { # pods_not_ready <ns>...
  local ns
  for ns in "$@"; do
    kubectl get pods -n "$ns" -o json | jq -r --arg ns "$ns" '
      .items[] | select(.status.phase != "Succeeded")
      | select(([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length) == 0)
      | "\($ns)/\(.metadata.name)"'
  done
}

# ---- env.json ---------------------------------------------------------------
env_set() { # env_set <key> <json-value>   e.g. env_set infra_ready true
  local tmp
  [ -f "$ENV_JSON" ] || echo '{}' > "$ENV_JSON"
  tmp="$(mktemp)"
  jq --argjson v "$2" ".$1 = \$v" "$ENV_JSON" > "$tmp" && mv "$tmp" "$ENV_JSON"
}
env_set_str() { env_set "$1" "$(jq -n --arg v "$2" '$v')"; }

# ---- Grafana ------------------------------------------------------------------
GF_PASS=""

gf_init() { # call once from the main shell before gf_api
  GF_PASS="$(tf_out grafana_admin_password)"
  [ -n "$GF_PASS" ] || die "could not read terraform output grafana_admin_password"
}

# TLS: the Gateway serves a cert-manager certificate signed by a self-signed CA
# (issuer lgtm-ca) that is not in any trust store. One switch controls this for every script:
#   LGTM_TLS_INSECURE=1 (default)  curl -k (self-signed CA)
#   LGTM_TLS_INSECURE=0            normal verification (after trusting the CA, see trust-ca.sh)
LGTM_TLS_INSECURE="${LGTM_TLS_INSECURE:-1}"
CURL_TLS=(--proto =https)   # never empty (bash 3.2 + set -u)
[ "$LGTM_TLS_INSECURE" = "1" ] && CURL_TLS+=(-k)

_normalize_url() { case "$1" in http://*|https://*) printf '%s' "${1%/}" ;; *) printf 'https://%s' "${1%/}" ;; esac; }
host_of() { local h="${1#*://}"; printf '%s' "${h%%[/:]*}"; }

grafana_base_url() {
  local u="${GRAFANA_URL:-}"
  [ -n "$u" ] || u="$(tf_out grafana_url)"
  [ -n "$u" ] || return 1
  _normalize_url "$u"
}

shop_base_url() {
  local u="${SHOP_URL:-}"
  [ -n "$u" ] || u="$(tf_out shop_url)"
  [ -n "$u" ] || return 1
  _normalize_url "$u"
}

# Resolve a hostname (the Gateway NLB) to its addresses/CNAME targets (one per line) using dig, host or nslookup.
resolve_host() {
  if command -v dig >/dev/null 2>&1; then dig +short "$1" 2>/dev/null
  elif command -v host >/dev/null 2>&1; then host "$1" 2>/dev/null | awk '/has address|is an alias for/ {print $NF}'
  else nslookup "$1" 2>/dev/null | awk '/^Address: / {print $2}'
  fi
}

# ---- Gateway API (Envoy Gateway) ---------------------------------------------------
# Envoy proxy Service(s) created by Envoy Gateway carry this label (cluster-wide lookup).
envoy_proxy_svc_json() {
  kubectl get svc -A -l gateway.envoyproxy.io/owning-gateway-name -o json 2>/dev/null
}

_gf_curl_cfg() {
  local p="${GF_PASS//\\/\\\\}"
  p="${p//\"/\\\"}"
  printf 'user = "admin:%s"\n' "$p"
}

# gf_api <METHOD> <path> [extra curl args...]; prints response body.
gf_api() {
  local method="$1" path="$2" base
  shift 2
  base="$(grafana_base_url)" || return 1
  curl -sS -f -m 30 "${CURL_TLS[@]}" -X "$method" -K <(_gf_curl_cfg) -H 'Content-Type: application/json' "$@" "$base$path"
}

# Health of a datasource by uid; prints status and message, returns 0 if OK.
gf_ds_health() {
  local uid="$1" out status
  out="$(gf_api GET "/api/datasources/uid/$uid/health" 2>&1)" || { echo "unreachable or error: ${out:0:200}"; return 1; }
  status="$(jq -r '.status // "unknown"' <<<"$out" 2>/dev/null || echo unknown)"
  echo "$status $(jq -r '.message // ""' <<<"$out" 2>/dev/null)"
  [ "$status" = "OK" ]
}

# ---- Astronomy Shop -------------------------------------------------------------
# ConfigMap in astronomy-shop holding the flagd flag file (key demo.flagd.json).
find_flag_cm() {
  kubectl get cm -n "$NS_SHOP" -o json \
    | jq -r '.items[] | select(.data["demo.flagd.json"] != null) | .metadata.name' | head -n1
}

shop_svc() { # first existing service name from the candidates
  local s
  for s in frontend-proxy frontendproxy frontend; do
    if kubectl get svc -n "$NS_SHOP" "$s" >/dev/null 2>&1; then printf '%s' "$s"; return 0; fi
  done
  return 1
}
