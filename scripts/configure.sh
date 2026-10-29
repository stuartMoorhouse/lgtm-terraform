#!/usr/bin/env bash
# Post-deploy verification and env.json update. Idempotent, read-only against the cluster.
# TLS: see LGTM_TLS_INSECURE in lib.sh (default 1 = skip verification; the CA is self-signed, see trust-ca.sh).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need aws kubectl terraform jq curl

TIMEOUT="${TIMEOUT:-600}"

log "Verifying AWS account"
acct="$(check_account)"; log "Account $acct OK"

setup_kubeconfig
kube_ok || die "cannot reach cluster (kubectl get ns $NS_LGTM failed). Check your IP/VPN and kubeconfig."

for ns in "$NS_LGTM" "$NS_SHOP"; do
  log "Waiting for pods Ready in $ns (timeout ${TIMEOUT}s)"
  kubectl wait --for=condition=Ready pod --all -n "$ns" \
    --field-selector=status.phase!=Succeeded --timeout="${TIMEOUT}s" \
    || { pods_not_ready "$ns" >&2; die "pods not Ready in $ns"; }
done
env_set infra_ready true

GURL="$(grafana_base_url)" || die "terraform output grafana_url is empty (NLB not created yet? re-run apply/refresh)"
SURL="$(shop_base_url)" || die "terraform output shop_url is empty (NLB not created yet? re-run apply/refresh)"
NLB_HOST="$(host_of "$GURL")"

log "Waiting for NLB hostname to resolve: $NLB_HOST"
end=$((SECONDS + TIMEOUT)); dns_ok=0
while [ $SECONDS -lt $end ]; do
  if [ -n "$(resolve_host "$NLB_HOST")" ]; then dns_ok=1; break; fi
  sleep 10
done
[ "$dns_ok" -eq 1 ] || die "NLB hostname $NLB_HOST did not resolve within ${TIMEOUT}s (NLB DNS can take a few minutes)"

log "Waiting for Gateway(s) Programmed and Certificates Ready"
kubectl wait --for=condition=Programmed gateway --all -A --timeout="${TIMEOUT}s" \
  || die "Gateway not Programmed (kubectl get gateway -A)"
kubectl wait --for=condition=Ready certificate --all -A --timeout="${TIMEOUT}s" \
  || { kubectl get certificate -A >&2 || true; die "Certificates not Ready (check issuer lgtm-ca: kubectl get clusterissuer,issuer -A)"; }

log "Waiting for Grafana over HTTPS: $GURL"
end=$((SECONDS + TIMEOUT)); ok=0
while [ $SECONDS -lt $end ]; do
  if curl -s -o /dev/null -m 10 "${CURL_TLS[@]}" "$GURL/api/health"; then ok=1; break; fi
  sleep 10
done
[ "$ok" -eq 1 ] || die "Grafana not reachable at $GURL within ${TIMEOUT}s. Check your IP is in allowed_cidr."
env_set_str grafana_url "$GURL"
env_set_str shop_url "$SURL"

gf_init
fail=0
for uid in loki tempo mimir; do
  if res="$(gf_ds_health "$uid")"; then log "datasource $uid: $res"
  else log "datasource $uid UNHEALTHY: $res"; fail=1; fi
done

dash="$(gf_api GET '/api/search?type=dash-db' | jq 'length')" || die "dashboard search failed"
rules="$(gf_api GET /api/v1/provisioning/alert-rules | jq 'length')" || die "alert rule query failed"
log "dashboards: $dash, alert rules: $rules"
[ "$dash" -gt 0 ] || { log "no dashboards provisioned"; fail=1; }
[ "$rules" -gt 0 ] || { log "no alert rules provisioned"; fail=1; }

if [ "$fail" -eq 0 ]; then
  env_set config_ready true
  log "Configuration verified. env.json updated."
else
  env_set config_ready false
  die "one or more checks failed (see above)"
fi
