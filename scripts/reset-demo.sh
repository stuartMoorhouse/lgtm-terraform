#!/usr/bin/env bash
# Reset the demo: disable all injected flags, restart the load generator.
# --wipe also restarts all astronomy-shop deployments. S3 data is never touched.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl jq

WIPE=0
[ "${1:-}" = "--wipe" ] && WIPE=1

cm="$(find_flag_cm)"; [ -n "$cm" ] || die "no flagd ConfigMap in $NS_SHOP"
json="$(kubectl get cm -n "$NS_SHOP" "$cm" -o json | jq -r '.data["demo.flagd.json"]')"
# loadGeneratorTraffic/loadGeneratorVUs are load knobs, not incidents: leave them as-is.
json="$(jq '.flags |= with_entries(select(.key|startswith("loadGenerator")|not).value.defaultVariant = (if (.value.variants|has("off")) then "off" else .value.defaultVariant end) // .)' <<<"$json")"
kubectl patch cm -n "$NS_SHOP" "$cm" --type merge \
  -p "$(jq -n --arg j "$json" '{data: {"demo.flagd.json": $j}}')" >/dev/null
log "All flags set to off in ConfigMap $cm"

if kubectl get deploy -n "$NS_SHOP" flagd >/dev/null 2>&1; then
  kubectl rollout restart -n "$NS_SHOP" deploy/flagd >/dev/null
  kubectl rollout status -n "$NS_SHOP" deploy/flagd --timeout=120s >/dev/null
fi

for d in load-generator loadgenerator; do
  if kubectl get deploy -n "$NS_SHOP" "$d" >/dev/null 2>&1; then
    kubectl rollout restart -n "$NS_SHOP" "deploy/$d" >/dev/null
    log "Restarted $d"
    break
  fi
done

if [ "$WIPE" -eq 1 ]; then
  log "Restarting all deployments in $NS_SHOP"
  kubectl rollout restart -n "$NS_SHOP" deploy >/dev/null
  kubectl rollout status -n "$NS_SHOP" deploy --timeout=300s >/dev/null 2>&1 || log "some rollouts still in progress"
fi
log "Reset complete"
