#!/usr/bin/env bash
# Enable/disable Astronomy Shop feature flags to inject faults.
# Usage: trigger-incidents.sh list | enable <flag> | disable <flag>
#
# Mechanism: the OpenTelemetry demo reads flags from flagd, which loads a JSON file
# (demo.flagd.json) mounted from a ConfigMap in astronomy-shop. Each flag has
# state/variants/defaultVariant. "enable" sets defaultVariant to the first non-"off"
# variant (e.g. "on", "100%", "10sec"); "disable" sets it to "off". We edit the
# ConfigMap with kubectl+jq (merge patch) and then restart the flagd deployment,
# because newer chart versions copy the file into an emptyDir at start and
# otherwise ConfigMap changes would not be picked up promptly.
# Documented flags (https://opentelemetry.io/docs/demo/feature-flags/, checked 2026-10-29):
# adFailure, adHighCpu, adManualGc, aiRunawayAgent, aiSlowResponse, cartFailure,
# emailMemoryLeak, failedReadinessProbe, imageSlowLoad, intlShippingSlowdown,
# kafkaConsumerDead, kafkaQueueProblems, loadGeneratorTraffic, loadGeneratorVUs,
# paymentFailure, paymentUnreachable, productCatalogFailure,
# productCatalogLockContention, recommendationCacheFailure.
# Good demo incidents: productCatalogFailure, cartFailure, adHighCpu, paymentFailure.
# The docs describe changing flags via flagd-ui (/feature) or its raw JSON editor, not via
# the ConfigMap; the ConfigMap edit below is equivalent to the Advanced View but is an
# assumption about this chart's layout. Flag names are validated against the live ConfigMap.
# loadGenerator* flags are tuning knobs, not incidents: reset-demo.sh leaves them alone.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl jq

usage() { sed -n '2,3p' "$0"; exit 1; }
cmd="${1:-}"; flag="${2:-}"

cm="$(find_flag_cm)"; [ -n "$cm" ] || die "no ConfigMap with key demo.flagd.json in $NS_SHOP (is the demo deployed?)"
json="$(kubectl get cm -n "$NS_SHOP" "$cm" -o json | jq -r '.data["demo.flagd.json"]')"

set_flag() { # set_flag <flag> <on|off>  (modifies $json)
  local f="$1" mode="$2"
  jq -e --arg f "$f" '.flags[$f]' <<<"$json" >/dev/null \
    || die "unknown flag '$f'. Run: $0 list"
  json="$(jq --arg f "$f" --arg m "$mode" '
    (.flags[$f].variants | keys) as $k
    | .flags[$f].defaultVariant =
        (if $m == "off" then (if ($k|index("off")) then "off" else $k[0] end)
         else ([$k[] | select(. != "off")] | .[0] // $k[0]) end)' <<<"$json")"
}

apply() {
  local patch
  patch="$(jq -n --arg j "$json" '{data: {"demo.flagd.json": $j}}')"
  kubectl patch cm -n "$NS_SHOP" "$cm" --type merge -p "$patch" >/dev/null
  if kubectl get deploy -n "$NS_SHOP" flagd >/dev/null 2>&1; then
    kubectl rollout restart -n "$NS_SHOP" deploy/flagd >/dev/null
    kubectl rollout status -n "$NS_SHOP" deploy/flagd --timeout=120s >/dev/null
  else
    log "flagd deployment not found; relying on ConfigMap propagation (up to ~60s)"
  fi
}

case "$cmd" in
  list)
    jq -r '.flags | to_entries[] | "\(.key)\t\(.value.defaultVariant)\t\(.value.description // "")"' <<<"$json" \
      | column -t -s $'\t' ;;
  enable|disable)
    [ -n "$flag" ] || usage
    set_flag "$flag" "$([ "$cmd" = enable ] && echo on || echo off)"
    apply
    log "$flag -> $(jq -r --arg f "$flag" '.flags[$f].defaultVariant' <<<"$json")" ;;
  *) usage ;;
esac
