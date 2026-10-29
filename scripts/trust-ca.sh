#!/usr/bin/env bash
# Export the PUBLIC certificate of the cert-manager self-signed CA (issuer lgtm-ca) to
# results/lgtm-ca.crt and print (not run) the macOS command to trust it.
# Only ca.crt / tls.crt are read from the secret; the private key (tls.key) is never touched.
# Overrides: LGTM_ISSUER (default lgtm-ca), LGTM_CA_NAMESPACE (default cert-manager, used for a ClusterIssuer).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl jq openssl base64

ISSUER="${LGTM_ISSUER:-lgtm-ca}"
CA_NS="${LGTM_CA_NAMESPACE:-cert-manager}"
kube_ok || die "cannot reach cluster; run scripts/configure.sh first (kubeconfig)"

# Find the secret named by the CA issuer (ClusterIssuer first, then a namespaced Issuer).
secret="$(kubectl get clusterissuer "$ISSUER" -o jsonpath='{.spec.ca.secretName}' 2>/dev/null || true)"
if [ -z "$secret" ]; then
  line="$(kubectl get issuer -A -o json | jq -r --arg n "$ISSUER" \
    '.items[] | select(.metadata.name==$n) | "\(.metadata.namespace) \(.spec.ca.secretName)"' | head -n1)"
  [ -n "$line" ] || die "issuer '$ISSUER' not found (kubectl get clusterissuer,issuer -A)"
  CA_NS="${line% *}"; secret="${line#* }"
fi
[ -n "$secret" ] || die "issuer '$ISSUER' has no spec.ca.secretName"

# Select only public fields; never read tls.key.
b64="$(kubectl get secret -n "$CA_NS" "$secret" -o json | jq -r '.data["ca.crt"] // .data["tls.crt"] // empty')"
[ -n "$b64" ] || die "secret $CA_NS/$secret has no ca.crt or tls.crt"

mkdir -p "$RESULTS_DIR"
out="$RESULTS_DIR/lgtm-ca.crt"
printf '%s' "$b64" | base64 --decode > "$out"
openssl x509 -in "$out" -noout >/dev/null 2>&1 || { rm -f "$out"; die "exported data is not a valid certificate"; }

log "Exported public CA certificate to $out"
openssl x509 -in "$out" -noout -subject -enddate
echo
echo "To trust it on macOS (not run by this script):"
echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \"$out\""
echo "To remove later:"
echo "  sudo security delete-certificate -c \"<CA common name shown above>\" /Library/Keychains/System.keychain"
echo "After trusting, set LGTM_TLS_INSECURE=0 to verify TLS in the other scripts."
