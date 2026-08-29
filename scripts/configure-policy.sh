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
CHECKPOINT_RELEASE="$(output_value checkpoint_os_version)"
RG="$(output_value resource_group_name)"
GATEWAY_VM="$(output_value checkpoint_vm_name)"
GATEWAY_NSG_ID="$(output_value checkpoint_nsg_id)"
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
  "$CHECKPOINT_RELEASE"
)

transport="${CHECKPOINT_TRANSPORT:-auto}"
ssh_key="${CHECKPOINT_SSH_PRIVATE_KEY:-$HOME/.ssh/id_ed25519}"
ssh_wait_seconds="${CHECKPOINT_SSH_WAIT_SECONDS:-1800}"
ssh_retry_seconds="${CHECKPOINT_SSH_RETRY_SECONDS:-30}"
reconcile_ssh_rule="${CHECKPOINT_RECONCILE_SSH_RULE:-false}"
[[ "$ssh_wait_seconds" =~ ^[0-9]+$ ]] ||
  die "CHECKPOINT_SSH_WAIT_SECONDS must be a non-negative integer."
[[ "$ssh_retry_seconds" =~ ^[1-9][0-9]*$ ]] ||
  die "CHECKPOINT_SSH_RETRY_SECONDS must be a positive integer."
[[ "$reconcile_ssh_rule" == "true" || "$reconcile_ssh_rule" == "false" ]] ||
  die "CHECKPOINT_RECONCILE_SSH_RULE must be true or false."
ssh_options=(
  -i "$ssh_key"
  -o ConnectTimeout=15
  -o ServerAliveInterval=15
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$LOCAL_DIR/known_hosts"
)

use_ssh=false
if [[ "$transport" != "auto" && "$transport" != "ssh" && "$transport" != "run-command" ]]; then
  die "CHECKPOINT_TRANSPORT must be auto, ssh, or run-command."
fi
if [[ "$transport" == "ssh" && ! -f "$ssh_key" ]]; then
  die "CHECKPOINT_TRANSPORT=ssh requires private key $ssh_key."
fi

if [[ "$transport" != "run-command" && "$reconcile_ssh_rule" == "true" ]]; then
  ensure_restricted_ssh_nsg_rule "$SUBSCRIPTION" "$RG" "$GATEWAY_NSG_ID" "$MANAGEMENT_CIDR"
fi

if [[ "$transport" != "run-command" && -f "$ssh_key" ]]; then
  echo "Waiting up to ${ssh_wait_seconds}s for the Management API over restricted Gaia SSH..."
  ssh_deadline=$((SECONDS + ssh_wait_seconds))
  while true; do
    if ssh "${ssh_options[@]}" "admin@$PUBLIC_IP" \
      'command -v mgmt_cli >/dev/null &&
       command -v cp_log_export >/dev/null &&
       timeout 30 mgmt_cli -r true show packages limit 1 --format json >/dev/null 2>&1' \
      >/dev/null 2>&1; then
      use_ssh=true
      break
    fi
    ((SECONDS >= ssh_deadline)) && break
    if [[ "$reconcile_ssh_rule" == "true" ]]; then
      ensure_restricted_ssh_nsg_rule "$SUBSCRIPTION" "$RG" "$GATEWAY_NSG_ID" "$MANAGEMENT_CIDR"
    fi
    sleep "$ssh_retry_seconds"
  done
fi

if [[ "$transport" == "ssh" ]] && ! $use_ssh; then
  die "The Gaia Management API did not become ready over SSH within ${ssh_wait_seconds}s."
fi
if [[ "$transport" == "auto" ]] && ! $use_ssh; then
  echo "The Management API was unavailable over SSH; falling back to Azure VM Run Command."
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

if [[ "$TLS_ENABLED" == "true" ]]; then
  echo "Check Point L4/L7, Geo, TLS, routing policy, and Log Exporter configuration completed."
else
  echo "Check Point L4/L7, Geo, routing policy, and Log Exporter configuration completed; TLS inspection is disabled."
fi
