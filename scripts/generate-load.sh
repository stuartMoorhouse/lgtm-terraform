#!/usr/bin/env bash
# Extra traffic against the Astronomy Shop frontend via a local port-forward.
# Usage: generate-load.sh [-d seconds=300] [-c concurrency=5] [-p localport=18080]
# Service: frontend-proxy:8080 (OpenTelemetry demo chart default), falls back to frontend.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl curl

DURATION=300; CONC=5; PORT=18080
while getopts "d:c:p:h" o; do
  case "$o" in
    d) DURATION="$OPTARG" ;; c) CONC="$OPTARG" ;; p) PORT="$OPTARG" ;;
    *) sed -n '2,4p' "$0"; exit 1 ;;
  esac
done

svc="$(shop_svc)" || die "no frontend service found in $NS_SHOP (tried frontend-proxy, frontend)"
svcport="$(kubectl get svc -n "$NS_SHOP" "$svc" -o jsonpath='{.spec.ports[0].port}')"

pf_pid=""
worker_pids=()
cleanup() {
  trap - EXIT INT TERM
  if [ "${#worker_pids[@]}" -gt 0 ]; then kill "${worker_pids[@]}" 2>/dev/null || true; fi
  if [ -n "$pf_pid" ]; then kill "$pf_pid" 2>/dev/null || true; fi
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "Port-forward svc/$svc:$svcport -> localhost:$PORT"
kubectl port-forward -n "$NS_SHOP" "svc/$svc" "$PORT:$svcport" >/dev/null 2>&1 &
pf_pid=$!
for _ in $(seq 1 30); do
  curl -s -o /dev/null -m 2 "http://localhost:$PORT/" && break
  kill -0 "$pf_pid" 2>/dev/null || die "port-forward exited; is the cluster reachable?"
  sleep 1
done
curl -s -o /dev/null -m 5 "http://localhost:$PORT/" || die "frontend not reachable via port-forward"

base="http://localhost:$PORT"
paths=(/ /api/products /api/cart /api/recommendations /api/data /cart /product/OLJCESPC7Z /product/66VCHSJNUP /product/1YMWWN1N4O)
end=$((SECONDS + DURATION))
worker() {
  while [ $SECONDS -lt "$end" ]; do
    curl -s -o /dev/null -m 10 "$base${paths[RANDOM % ${#paths[@]}]}" || true
    sleep "0.$((RANDOM % 5))"
  done
}

log "Generating load: ${CONC} workers for ${DURATION}s"
for _ in $(seq 1 "$CONC"); do
  worker &
  worker_pids+=("$!")
done
wait "${worker_pids[@]}" 2>/dev/null || true
log "Done"
