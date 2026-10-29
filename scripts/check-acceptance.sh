#!/usr/bin/env bash
# Runs the scriptable acceptance checks (spec criteria 1-11) and writes
# results/acceptance-<timestamp>.txt. Nothing secret is printed or written.
# Exit code is non-zero if any criterion fails. Criterion 11 is manual.
# TLS: LGTM_TLS_INSECURE (lib.sh) controls curl -k for the self-signed CA; the certificate
# issuer itself is verified explicitly in criterion 3.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need aws kubectl terraform jq curl grep openssl

mkdir -p "$RESULTS_DIR"
OUT="$RESULTS_DIR/acceptance-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

PASSES=0; FAILS=0
pass() { printf 'PASS  %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
# run_check "<label>" fn ; fn prints detail on stdout and returns 0/1
run_check() {
  local label="$1" fn="$2" detail rc=0
  detail="$($fn 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then pass "$label${detail:+ - $detail}"; else fail "$label${detail:+ - $detail}"; fi
}

echo "Acceptance run $(date -u +%FT%TZ)"

# 1 -------------------------------------------------------------------
c1() { local a; a="$(aws sts get-caller-identity --profile company --query Account --output text 2>&1)" || { echo "$a"; return 1; }
       [ "$a" = "$EXPECTED_ACCOUNT" ] && echo "account $a" || { echo "account $a, expected $EXPECTED_ACCOUNT"; return 1; }; }
run_check "1  AWS account is $EXPECTED_ACCOUNT" c1

# Cluster access is needed for most remaining checks.
CLUSTER_OK=0
CLUSTER_NAME="$(tf_out cluster_name)"; REGION="$(tf_out region)"; REGION="${REGION:-us-east-1}"
KC="$(tf_out kubeconfig_command)"
[ -z "$KC" ] || bash -c "$KC" >/dev/null 2>&1 || true
kube_ok && CLUSTER_OK=1

# 2 -------------------------------------------------------------------
c2() {
  [ "$CLUSTER_OK" -eq 1 ] || { echo "cluster unreachable"; return 1; }
  local bad; bad="$(pods_not_ready "$NS_LGTM" "$NS_SHOP")"
  [ -z "$bad" ] || { echo "not Ready: $(echo "$bad" | tr '\n' ' ')"; return 1; }
  echo "all pods Ready in $NS_LGTM and $NS_SHOP"
}
run_check "2  All pods Ready" c2

# 3 -------------------------------------------------------------------
GF_OK=0
GF_URL="$(grafana_base_url || true)"; SHOP_URL_RES="$(shop_base_url || true)"
if [ -n "$GF_URL" ] && gf_init 2>/dev/null; then GF_OK=1; fi
NLB="$(tf_out gateway_nlb_hostname)"
[ -n "$NLB" ] || NLB="$(host_of "${GF_URL:-}")"
c3a() {
  [ -n "$GF_URL" ] && [ -n "$SHOP_URL_RES" ] || { echo "grafana_url/shop_url outputs empty (NLB not created yet?)"; return 1; }
  [ -n "$NLB" ] || { echo "no NLB hostname"; return 1; }
  [ -n "$(resolve_host "$NLB")" ] && echo "$NLB resolves" || { echo "$NLB does not resolve"; return 1; }
}
run_check "3a Gateway NLB hostname resolves" c3a

c3b() {
  local gc sc
  gc="$(curl -s -o /dev/null -m 15 "${CURL_TLS[@]}" -w '%{http_code}' "$GF_URL/api/health" || true)"
  sc="$(curl -s -o /dev/null -m 15 "${CURL_TLS[@]}" -w '%{http_code}' "$SHOP_URL_RES/" || true)"
  [ "$gc" = "200" ] && [[ "$sc" =~ ^[23] ]] && echo "/grafana/api/health HTTP $gc, / HTTP $sc from this IP" \
    || { echo "/grafana/api/health HTTP $gc, / HTTP $sc (expected 200 and 2xx/3xx)"; return 1; }
}
run_check "3b HTTPS responds from this IP" c3b

c3c() {
  local iss
  iss="$(openssl s_client -connect "$NLB:443" -servername "$NLB" </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)"
  [ -n "$iss" ] || { echo "could not read certificate from $NLB:443"; return 1; }
  grep -qi 'lgtm' <<<"$iss" && echo "$iss" || { echo "issuer is not the lgtm self-signed CA ($iss)"; return 1; }
}
run_check "3c Certificate issued by the lgtm self-signed CA" c3c

c3d() {
  [ "$CLUSTER_OK" -eq 1 ] || { echo "cluster unreachable"; return 1; }
  local ranges sp
  ranges="$(envoy_proxy_svc_json | jq -r '[.items[].spec.loadBalancerSourceRanges // [] | .[]] | join(",")')"
  sp="$(kubectl get securitypolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  case ",$ranges," in *,0.0.0.0/0,*) echo "Envoy proxy Service is open to 0.0.0.0/0"; return 1 ;; esac
  if [ -n "$ranges" ]; then echo "envoy proxy Service sourceRanges=$ranges, SecurityPolicies=$sp"
  elif [ "$sp" -gt 0 ]; then echo "no Service sourceRanges, but $sp SecurityPolicy object(s) present"
  else echo "no loadBalancerSourceRanges and no SecurityPolicy found"; return 1; fi
}
run_check "3d IP restriction in place (Service sourceRanges / SecurityPolicy)" c3d
echo "NOTE    3 manual: from a different IP (e.g. phone hotspot) confirm 'curl -k --max-time 10 $GF_URL/api/health' times out or returns 403."

# 4 -------------------------------------------------------------------
c4a() {
  [ "$GF_OK" -eq 1 ] || { echo "no password/URL"; return 1; }
  local code
  code="$(curl -s -o /dev/null -m 15 "${CURL_TLS[@]}" -w '%{http_code}' -K <(_gf_curl_cfg) "$GF_URL/api/user" || true)"
  [ "$code" = "200" ] && echo "admin login OK" || { echo "login returned HTTP $code"; return 1; }
}
run_check "4a Grafana login with generated admin password" c4a

c4b() {
  [ "$GF_OK" -eq 1 ] || { echo "no password"; return 1; }
  local hits=0 f rel ns
  # Files: tracked / non-ignored if git repo, else a filtered find. Password via /dev/fd, not argv.
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r f; do
      [ -f "$ROOT_DIR/$f" ] || continue
      if grep -qIF -f <(printf '%s\n' "$GF_PASS") "$ROOT_DIR/$f"; then echo "password found in file: $f"; hits=$((hits + 1)); fi
    done < <(git -C "$ROOT_DIR" ls-files --cached --others --exclude-standard)
  else
    while IFS= read -r f; do
      if grep -qIF -f <(printf '%s\n' "$GF_PASS") "$f"; then echo "password found in file: ${f#"$ROOT_DIR"/}"; hits=$((hits + 1)); fi
    done < <(find "$ROOT_DIR" -type f \
      -not -path '*/.terraform/*' -not -path '*/.git/*' -not -path '*/.claude/*' -not -path '*/results/*' \
      -not -name 'terraform.tfstate*' -not -name '*.tfvars' -not -name '.env*' -not -name '.terraform.lock.hcl')
  fi
  # Helm values (all releases, including computed values)
  if [ "$CLUSTER_OK" -eq 1 ] && command -v helm >/dev/null 2>&1; then
    for ns in "$NS_LGTM" "$NS_SHOP"; do
      for rel in $(helm list -n "$ns" -q 2>/dev/null); do
        if helm get values -a -n "$ns" "$rel" 2>/dev/null | grep -qF -f <(printf '%s\n' "$GF_PASS"); then
          echo "password found in helm values: $ns/$rel"; hits=$((hits + 1))
        fi
      done
    done
  else
    echo "(helm values not checked: helm or cluster unavailable)"
  fi
  [ "$hits" -eq 0 ] || return 1
  echo "no password found in non-ignored files or helm values"
}
run_check "4b No admin password in tracked files or helm values" c4b

# 5 -------------------------------------------------------------------
c5() {
  [ "$GF_OK" -eq 1 ] || { echo "grafana not available"; return 1; }
  local uid res rc=0 out=""
  for uid in loki tempo mimir; do
    if res="$(gf_ds_health "$uid")"; then out+="$uid=OK "; else out+="$uid=FAIL($res) "; rc=1; fi
  done
  echo "$out"; return $rc
}
run_check "5  Loki, Tempo, Mimir datasources healthy" c5

NOW="$(date +%s)"; START=$((NOW - 1800))

# 6 -------------------------------------------------------------------
c6() {
  [ "$GF_OK" -eq 1 ] || { echo "grafana not available"; return 1; }
  local n
  n="$(gf_api GET /api/datasources/proxy/uid/tempo/api/search -G \
        --data-urlencode 'q={resource.service.name="frontend"}' \
        --data-urlencode "start=$START" --data-urlencode "end=$NOW" --data-urlencode 'limit=5' \
      | jq '.traces | length')" || { echo "tempo search failed"; return 1; }
  [ "$n" -gt 0 ] && echo "$n+ traces for service frontend in last 30m" || { echo "no traces for service frontend"; return 1; }
}
run_check "6  Tempo has traces for frontend" c6

# 7 -------------------------------------------------------------------
c7a() {
  [ "$GF_OK" -eq 1 ] || { echo "grafana not available"; return 1; }
  local n
  n="$(gf_api GET /api/datasources/proxy/uid/loki/loki/api/v1/query_range -G \
        --data-urlencode 'query={service_name=~".+"}' \
        --data-urlencode "start=${START}000000000" --data-urlencode "end=${NOW}000000000" --data-urlencode 'limit=5' \
      | jq '.data.result | length')" || { echo "loki query failed"; return 1; }
  [ "$n" -gt 0 ] && echo "$n log streams" || { echo "no log streams with service_name label"; return 1; }
}
run_check "7a Loki returns logs" c7a

c7b() {
  [ "$GF_OK" -eq 1 ] || { echo "grafana not available"; return 1; }
  # astronomy-shop series: OTLP resource attrs land as job (Mimir: <namespace>/<service.name>),
  # service_name or k8s_namespace_name depending on the Alloy pipeline; accept any of them.
  local re='.*(frontend|checkout|cart|product-catalog|currency|payment|recommendation|ad).*' q n
  q="count({job=~\"$re\"}) or count({service_name=~\"$re\"}) or count({k8s_namespace_name=\"astronomy-shop\"})"
  n="$(gf_api GET /api/datasources/proxy/uid/mimir/api/v1/query -G --data-urlencode "query=$q" \
      | jq '[.data.result[].value[1] | tonumber] | add // 0')" || { echo "mimir query failed"; return 1; }
  [ "$n" -gt 0 ] && echo "$n series for astronomy-shop services" || { echo "no astronomy-shop series (job/service_name/k8s_namespace_name)"; return 1; }
}
run_check "7b Mimir returns metrics" c7b

# 8 -------------------------------------------------------------------
c8() {
  [ "$GF_OK" -eq 1 ] || { echo "grafana not available"; return 1; }
  local j
  j="$(gf_api GET /api/datasources/uid/tempo)" || { echo "cannot read tempo datasource"; return 1; }
  jq -e '.jsonData | (.tracesToLogsV2 // .tracesToLogs) != null and .tracesToMetrics != null' <<<"$j" >/dev/null \
    && echo "tracesToLogs and tracesToMetrics configured" \
    || { echo "tracesToLogs/tracesToMetrics missing in tempo jsonData"; return 1; }
}
run_check "8  Trace-to-logs and trace-to-metrics correlation configured" c8

# 9 -------------------------------------------------------------------
c9() {
  [ "$GF_OK" -eq 1 ] || { echo "grafana not available"; return 1; }
  local titles rules
  titles="$(gf_api GET '/api/search?type=dash-db' | jq -r '.[].title')" || { echo "dashboard search failed"; return 1; }
  rules="$(gf_api GET /api/v1/provisioning/alert-rules | jq 'length')" || { echo "alert rule query failed"; return 1; }
  grep -qi 'astronomy' <<<"$titles" || { echo "no Astronomy Shop dashboard"; return 1; }
  grep -qi 'kubernetes' <<<"$titles" || { echo "no Kubernetes dashboard"; return 1; }
  [ "$rules" -gt 0 ] || { echo "no alert rules"; return 1; }
  echo "$(wc -l <<<"$titles" | tr -d ' ') dashboards, $rules alert rules"
}
run_check "9  Dashboards and alert rules provisioned" c9

# 10 ------------------------------------------------------------------
c10a() {
  local buckets b rc=0 enc lc
  buckets="$(tf_bucket_names)"
  [ -n "$buckets" ] || { echo "no bucket names in terraform outputs (expected output names containing 'bucket')"; return 1; }
  for b in $buckets; do
    enc="$(aws s3api get-bucket-encryption --bucket "$b" --profile company \
      --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>&1)" \
      || { echo "$b: no encryption ($enc)"; rc=1; continue; }
    lc="$(aws s3api get-bucket-lifecycle-configuration --bucket "$b" --profile company 2>&1)" \
      || { echo "$b: no lifecycle ($lc)"; rc=1; continue; }
    if jq -e '[.Rules[] | select(.Status=="Enabled" and .Expiration.Days != null and .Expiration.Days <= 7)] | length > 0' <<<"$lc" >/dev/null; then
      echo "$b: $enc, 7d expiry"
    else
      echo "$b: encrypted but no enabled lifecycle rule with expiry <= 7 days"; rc=1
    fi
  done
  return $rc
}
run_check "10a S3 buckets SSE-encrypted with 7-day lifecycle" c10a

c10b() {
  [ -n "$CLUSTER_NAME" ] || { echo "cluster_name output empty"; return 1; }
  local ids vpc nat ids_all vols bad total
  ids="$(aws ec2 describe-instances --region "$REGION" --profile company \
    --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].[InstanceId,VpcId]' --output text)" || { echo "describe-instances failed"; return 1; }
  [ -n "$ids" ] || { echo "no running EKS node instances found for $CLUSTER_NAME"; return 1; }
  vpc="$(awk 'NR==1{print $2}' <<<"$ids")"
  nat="$(aws ec2 describe-instances --region "$REGION" --profile company \
    --filters "Name=vpc-id,Values=$vpc" "Name=tag:Name,Values=*fck-nat*" "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].InstanceId' --output text)" || { echo "describe-instances (fck-nat) failed"; return 1; }
  [ -n "$nat" ] || { echo "fck-nat instance not found in $vpc (tag Name=*fck-nat*)"; return 1; }
  ids_all="$(awk '{print $1}' <<<"$ids" | tr '\n' ',')${nat// /,}"
  vols="$(aws ec2 describe-volumes --region "$REGION" --profile company \
    --filters "Name=attachment.instance-id,Values=$ids_all" --query 'Volumes[].[VolumeId,Encrypted]' --output json)" \
    || { echo "describe-volumes failed"; return 1; }
  total="$(jq 'length' <<<"$vols")"
  bad="$(jq -r '[.[] | select(.[1] != true) | .[0]] | join(",")' <<<"$vols")"
  [ "$total" -gt 0 ] || { echo "no volumes found"; return 1; }
  [ -z "$bad" ] || { echo "unencrypted volumes: $bad"; return 1; }
  echo "$total volumes (EKS nodes + fck-nat), all encrypted"
}
run_check "10b EBS volumes encrypted" c10b

# 11 ------------------------------------------------------------------
echo "MANUAL  11 Run 'terraform -chdir=terraform destroy' and confirm it completes with no leftover VPC, ENIs or buckets,"
echo "           and that the Gateway NLB, the VPC and the S3 buckets are gone."

echo
echo "Summary: $PASSES passed, $FAILS failed (criterion 11 manual). Results: $OUT"
[ "$FAILS" -eq 0 ]
