#!/usr/bin/env bash
# Print Grafana (/grafana) and storefront (/) URLs and login instructions.
# Password only shown with --show-password.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need terraform

g="$(tf_out grafana_url)"; s="$(tf_out shop_url)"
[ -n "$g" ] || g="(terraform output grafana_url is empty; has apply completed?)"
[ -n "$s" ] || s="(terraform output shop_url is empty; has apply completed?)"

echo "Grafana URL : $g"
echo "Shop URL    : $s"
echo "Username    : admin"
if [ "${1:-}" = "--show-password" ]; then
  echo "Password    : $(tf_out_req grafana_admin_password)"
else
  echo "Password    : run: terraform -chdir=terraform output -raw grafana_admin_password"
  echo "              (or pass --show-password to this script)"
fi
echo
echo "Note: the certificate is signed by a self-signed CA (issuer lgtm-ca), so browsers warn."
echo "Access is restricted to the allowed_cidr source range."
echo "To trust the CA locally: scripts/trust-ca.sh (exports the public cert and prints the macOS trust command)."
