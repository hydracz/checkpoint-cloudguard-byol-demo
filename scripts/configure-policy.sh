#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

load_runtime_environment
require_cmd az
require_cmd openssl

outputs="$("$TERRAFORM" -chdir="$INFRA" output -json)"
output_value() {
  printf '%s' "$outputs" | jq -r --arg key "$1" '
    if has($key) then .[$key].value
    else error("missing Terraform output: " + $key)
    end
  '
}

SUBSCRIPTION="$(output_value subscription_id)"
MANAGEMENT_CIDR="$(output_value management_cidr)"
COMPANY_DOMAIN="$(output_value company_domain)"
RG="$(output_value resource_group_name)"
GATEWAY_VM="$(output_value checkpoint_vm_name)"
GATEWAY_NAME="$(output_value checkpoint_gateway_name)"
PACKAGE_NAME="$(output_value policy_package_name)"
FRONTEND_IP="$(output_value checkpoint_frontend_private_ip)"
BACKEND_IP="$(output_value checkpoint_backend_private_ip)"
COLLECTOR_IP="$(output_value collector_private_ip)"
EU_CIDR="$(output_value eu_spoke_address_space)"
REMOTE_CIDR="$(output_value remote_spoke_address_space)"
EU_HOST_IP="$(output_value eu_workload_private_ip)"
PUBLIC_IP="$(output_value checkpoint_public_ip)"
TLS_ENABLED="$(output_value enable_tls_inspection)"
INBOUND_ENABLED="$(output_value enable_inbound_demo)"
INBOUND_SOURCE_CIDR="$(output_value inbound_demo_source_cidr)"
INBOUND_SOURCE_CIDR="${INBOUND_SOURCE_CIDR:-disabled}"
COUNTRIES_B64="$(printf '%s' "$outputs" | jq -c '.blocked_countries.value' | openssl base64 -A)"
APPLICATIONS_B64="$(printf '%s' "$outputs" | jq -c '.blocked_applications.value' | openssl base64 -A)"
URLS_B64="$(printf '%s' "$outputs" | jq -c '.blocked_urls.value' | openssl base64 -A)"

mkdir -p "$LOCAL_DIR"
policy_args=(
  "$GATEWAY_NAME"
  "$PACKAGE_NAME"
  "$FRONTEND_IP"
  "$BACKEND_IP"
  "$COLLECTOR_IP"
  "$EU_CIDR"
  "$REMOTE_CIDR"
  "$EU_HOST_IP"
  "$COUNTRIES_B64"
  "$APPLICATIONS_B64"
  "$URLS_B64"
  "$TLS_ENABLED"
  "$INBOUND_ENABLED"
  "$INBOUND_SOURCE_CIDR"
  "$PUBLIC_IP"
  "$MANAGEMENT_CIDR"
  "$COMPANY_DOMAIN"
)

transport="${CHECKPOINT_TRANSPORT:-auto}"
ssh_key="${CHECKPOINT_SSH_PRIVATE_KEY:-$HOME/.ssh/id_ed25519}"
ssh_options=(
  -i "$ssh_key"
  -o ConnectTimeout=15
  -o ServerAliveInterval=15
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$LOCAL_DIR/known_hosts"
)

use_ssh=false
if [[ "$transport" == "ssh" ]]; then
  use_ssh=true
elif [[ "$transport" == "auto" && -f "$ssh_key" ]] &&
  ssh "${ssh_options[@]}" "admin@$PUBLIC_IP" true >/dev/null 2>&1; then
  use_ssh=true
elif [[ "$transport" != "auto" && "$transport" != "run-command" ]]; then
  die "CHECKPOINT_TRANSPORT must be auto, ssh, or run-command."
fi

if $use_ssh; then
  echo "Configuring Check Point policy over restricted SSH as Gaia admin."
  if ! ssh "${ssh_options[@]}" "admin@$PUBLIC_IP" bash -s -- "${policy_args[@]}" \
    <"$ROOT/scripts/checkpoint-policy.sh" \
    >"$LOCAL_DIR/checkpoint-policy-output.txt" \
    2>"$LOCAL_DIR/checkpoint-policy-stderr.log"; then
    tail -80 "$LOCAL_DIR/checkpoint-policy-stderr.log" >&2
    die "Check Point policy script failed over SSH."
  fi
  message="$(cat "$LOCAL_DIR/checkpoint-policy-output.txt")"
else
  echo "Configuring Check Point policy through Azure VM Run Command; first boot can take 20-30 minutes."
  az vm run-command invoke \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RG" \
    --name "$GATEWAY_VM" \
    --command-id RunShellScript \
    --scripts @"$ROOT/scripts/checkpoint-policy.sh" \
    --parameters "${policy_args[@]}" \
    --only-show-errors \
    -o json >"$LOCAL_DIR/checkpoint-policy-run-command.json"
  message="$(jq -r '.value[]?.message' "$LOCAL_DIR/checkpoint-policy-run-command.json")"
fi

grep -q 'DEMO_POLICY_STATUS=complete' <<<"$message" ||
  die "Check Point policy script did not report completion. See $LOCAL_DIR/checkpoint-policy-*."

if [[ "$TLS_ENABLED" == "true" ]]; then
  ca_b64="$(tr -d '\r' <<<"$message" | sed -n 's/^DEMO_TLS_CA_B64=//p' | tail -1)"
  [[ -n "$ca_b64" ]] || die "HTTPS inspection was enabled but no public CA was returned."
  printf '%s' "$ca_b64" | openssl base64 -d -A >"$LOCAL_DIR/checkpoint-demo-ca.pem"
  openssl x509 -in "$LOCAL_DIR/checkpoint-demo-ca.pem" -noout -subject -dates >/dev/null

  ca_pem_b64="$(openssl base64 -A -in "$LOCAL_DIR/checkpoint-demo-ca.pem")"
  install_command="printf '%s' '$ca_pem_b64' | base64 -d > /usr/local/share/ca-certificates/checkpoint-demo-ca.crt && update-ca-certificates"
  for vm_output in eu_workload_vm_name remote_workload_vm_name; do
    vm_name="$(output_value "$vm_output")"
    az vm run-command invoke \
      --subscription "$SUBSCRIPTION" \
      --resource-group "$RG" \
      --name "$vm_name" \
      --command-id RunShellScript \
      --scripts "$install_command" \
      --only-show-errors \
      -o none
  done
fi

echo "Check Point L4/L7, Geo, TLS, routing policy, and Log Exporter configuration completed."
