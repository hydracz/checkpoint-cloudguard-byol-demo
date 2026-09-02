#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

OUTPUTS_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --outputs-file)
      [[ $# -ge 2 ]] || die "--outputs-file requires a path."
      [[ -f "$2" ]] || die "Terraform outputs file not found: $2"
      OUTPUTS_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
      shift 2
      ;;
    *)
      die "Usage: $0 [--outputs-file FILE]"
      ;;
  esac
done

require_cmd az
require_cmd openssl

trace_outputs=false
if [[ "$-" == *x* ]]; then
  trace_outputs=true
  set +x
fi
outputs="$(load_terraform_outputs "$OUTPUTS_FILE")"
output_value() {
  printf '%s' "$outputs" | jq -r --arg key "$1" '
    if has($key) then .[$key].value
    else error("missing Terraform output: " + $key)
    end
  '
}

SUBSCRIPTION="$(output_value subscription_id)"
MANAGEMENT_CIDRS_JSON="$(printf '%s' "$outputs" | jq -e -c '.management_cidrs.value')"
MANAGEMENT_CIDRS_B64="$(printf '%s' "$MANAGEMENT_CIDRS_JSON" | openssl base64 -A)"
COMPANY_DOMAIN="$(output_value company_domain)"
CHECKPOINT_RELEASE="$(output_value checkpoint_os_version)"
RG="$(output_value resource_group_name)"
GATEWAY_VM="$(output_value checkpoint_vm_name)"
GATEWAY_NSG_ID="$(printf '%s' "$outputs" | jq -r '.checkpoint_nsg_id.value // ""')"
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
R81_TLS_MANUAL="$(printf '%s' "$outputs" | jq -r '.r81_tls_manually_configured.value // false')"
EU_WORKLOAD_VM="$(output_value eu_workload_vm_name)"
REMOTE_WORKLOAD_VM="$(output_value remote_workload_vm_name)"
SKIP_POLICY_CONFIGURATION="$(
  printf '%s' "$outputs" | jq -r '
    if has("skip_policy_configuration") and
       .skip_policy_configuration.value != null
    then .skip_policy_configuration.value
    else true
    end
  '
)"
SKIP_POLICY_CONFIGURATION="${CHECKPOINT_SKIP_POLICY_CONFIGURATION:-$SKIP_POLICY_CONFIGURATION}"
INBOUND_ENABLED="$(output_value enable_inbound_demo)"
INBOUND_SOURCE_CIDR="$(output_value inbound_demo_source_cidr)"
INBOUND_SOURCE_CIDR="${INBOUND_SOURCE_CIDR:-disabled}"
COUNTRIES_B64="$(printf '%s' "$outputs" | jq -c '.blocked_countries.value' | openssl base64 -A)"
APPLICATIONS_B64="$(printf '%s' "$outputs" | jq -c '.blocked_applications.value' | openssl base64 -A)"
URLS_B64="$(printf '%s' "$outputs" | jq -c '.blocked_urls.value' | openssl base64 -A)"
[[ "$SKIP_POLICY_CONFIGURATION" == "true" || "$SKIP_POLICY_CONFIGURATION" == "false" ]] ||
  die "skip_policy_configuration must be true or false."
unset outputs
unset -f output_value
if $trace_outputs; then
  set -x
fi

mkdir -p "$LOCAL_DIR"
if [[ "$SKIP_POLICY_CONFIGURATION" == "false" &&
  "$TLS_ENABLED" == "true" &&
  "$CHECKPOINT_RELEASE" == "R81" &&
  "$R81_TLS_MANUAL" == "true" ]]; then
  ca_file="${CHECKPOINT_TLS_CA_FILE:-}"
  [[ -f "$ca_file" ]] ||
    die "R81 manual TLS mode requires CHECKPOINT_TLS_CA_FILE with the SmartConsole-exported public CA."
  if openssl x509 -in "$ca_file" -noout >/dev/null 2>&1; then
    openssl x509 -in "$ca_file" -out "$LOCAL_DIR/checkpoint-demo-ca.pem"
  elif openssl x509 -inform DER -in "$ca_file" -noout >/dev/null 2>&1; then
    openssl x509 -inform DER -in "$ca_file" -out "$LOCAL_DIR/checkpoint-demo-ca.pem"
  else
    die "CHECKPOINT_TLS_CA_FILE must contain a PEM or DER X.509 public certificate."
  fi
fi

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
  "$MANAGEMENT_CIDRS_B64"
  "$COMPANY_DOMAIN"
  "$CHECKPOINT_RELEASE"
  "$R81_TLS_MANUAL"
  "$SKIP_POLICY_CONFIGURATION"
)

transport="${CHECKPOINT_TRANSPORT:-auto}"
ssh_key="${CHECKPOINT_SSH_PRIVATE_KEY:-$DEFAULT_SSH_PRIVATE_KEY}"
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
if [[ "$SKIP_POLICY_CONFIGURATION" == "true" ]]; then
  readiness_description="Gaia CLI and Log Exporter"
  readiness_command='command -v clish >/dev/null &&
   command -v cp_conf >/dev/null &&
   command -v cp_log_export >/dev/null &&
   command -v timeout >/dev/null &&
   timeout 30 clish -c "show version all" >/dev/null 2>&1'
else
  readiness_description="Management API and Log Exporter"
  readiness_command='command -v mgmt_cli >/dev/null &&
   command -v cp_log_export >/dev/null &&
   timeout 30 mgmt_cli -r true show packages limit 1 --format json >/dev/null 2>&1'
fi

use_ssh=false
if [[ "$transport" != "auto" && "$transport" != "ssh" && "$transport" != "run-command" ]]; then
  die "CHECKPOINT_TRANSPORT must be auto, ssh, or run-command."
fi
if [[ "$transport" == "ssh" && ! -f "$ssh_key" ]]; then
  die "CHECKPOINT_TRANSPORT=ssh requires private key $ssh_key."
fi

if [[ "$transport" != "run-command" && "$reconcile_ssh_rule" == "true" ]]; then
  [[ -n "$GATEWAY_NSG_ID" ]] ||
    die "CHECKPOINT_RECONCILE_SSH_RULE=true requires a fresh Terraform apply that includes checkpoint_nsg_id."
  trap remove_temporary_restricted_ssh_nsg_rule EXIT
  ensure_restricted_ssh_nsg_rules "$SUBSCRIPTION" "$RG" "$GATEWAY_NSG_ID" "$MANAGEMENT_CIDRS_JSON"
fi

if [[ "$transport" != "run-command" && -f "$ssh_key" ]]; then
  echo "Waiting up to ${ssh_wait_seconds}s for the ${readiness_description} over Gaia SSH..."
  ssh_deadline=$((SECONDS + ssh_wait_seconds))
  while true; do
    if ssh "${ssh_options[@]}" "admin@$PUBLIC_IP" \
      "$readiness_command" \
      >/dev/null 2>&1; then
      use_ssh=true
      break
    fi
    ((SECONDS >= ssh_deadline)) && break
    if [[ "$reconcile_ssh_rule" == "true" ]]; then
      ensure_restricted_ssh_nsg_rules "$SUBSCRIPTION" "$RG" "$GATEWAY_NSG_ID" "$MANAGEMENT_CIDRS_JSON"
    fi
    sleep "$ssh_retry_seconds"
  done
fi

if [[ "$transport" == "ssh" ]] && ! $use_ssh; then
  die "The ${readiness_description} did not become ready over SSH within ${ssh_wait_seconds}s."
fi
if [[ "$transport" == "auto" ]] && ! $use_ssh; then
  echo "The ${readiness_description} was unavailable over SSH; falling back to Azure VM Run Command."
fi

rm -f \
  "$LOCAL_DIR/checkpoint-policy-output.txt" \
  "$LOCAL_DIR/checkpoint-policy-stderr.log" \
  "$LOCAL_DIR/checkpoint-policy-run-command.json"

if $use_ssh; then
  echo "Configuring the Check Point gateway over Gaia SSH as admin."
  if ! ssh "${ssh_options[@]}" "admin@$PUBLIC_IP" bash -s -- "${policy_args[@]}" \
    <"$ROOT/scripts/checkpoint-policy.sh" \
    >"$LOCAL_DIR/checkpoint-policy-output.txt" \
    2>"$LOCAL_DIR/checkpoint-policy-stderr.log"; then
    tail -80 "$LOCAL_DIR/checkpoint-policy-stderr.log" >&2
    die "Check Point gateway configuration script failed over SSH."
  fi
  message="$(cat "$LOCAL_DIR/checkpoint-policy-output.txt")"
else
  echo "Configuring the Check Point gateway through Azure VM Run Command; first boot can take 20-30 minutes."
  policy_run_command_args=()
  policy_arg_index=1
  for policy_arg in "${policy_args[@]}"; do
    policy_run_command_args+=("arg${policy_arg_index}=$policy_arg")
    policy_arg_index=$((policy_arg_index + 1))
  done
  az vm run-command invoke \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RG" \
    --name "$GATEWAY_VM" \
    --command-id RunShellScript \
    --scripts @"$ROOT/scripts/checkpoint-policy.sh" \
    --parameters "${policy_run_command_args[@]}" \
    --only-show-errors \
    -o json >"$LOCAL_DIR/checkpoint-policy-run-command.json"
  message="$(jq -r '.value[]?.message' "$LOCAL_DIR/checkpoint-policy-run-command.json")"
fi

grep -q 'DEMO_CONFIGURATION_STATUS=complete' <<<"$message" ||
  die "Check Point gateway configuration did not report completion. See $LOCAL_DIR/checkpoint-policy-*."

if [[ "$SKIP_POLICY_CONFIGURATION" == "false" && "$TLS_ENABLED" == "true" ]]; then
  if [[ "$CHECKPOINT_RELEASE" == "R81" && "$R81_TLS_MANUAL" == "true" ]]; then
    :
  else
    ca_b64="$(tr -d '\r' <<<"$message" | sed -n 's/^DEMO_TLS_CA_B64=//p' | tail -1)"
    [[ -n "$ca_b64" ]] || die "HTTPS inspection was enabled but no public CA was returned."
    printf '%s' "$ca_b64" | openssl base64 -d -A >"$LOCAL_DIR/checkpoint-demo-ca.pem"
  fi
  openssl x509 -in "$LOCAL_DIR/checkpoint-demo-ca.pem" -noout -subject -dates >/dev/null

  ca_pem_b64="$(openssl base64 -A -in "$LOCAL_DIR/checkpoint-demo-ca.pem")"
  install_command="printf '%s' '$ca_pem_b64' | base64 -d > /usr/local/share/ca-certificates/checkpoint-demo-ca.crt && update-ca-certificates"
  for vm_name in "$EU_WORKLOAD_VM" "$REMOTE_WORKLOAD_VM"; do
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

if [[ "$SKIP_POLICY_CONFIGURATION" == "true" ]]; then
  echo "Gaia routing, management access, and Log Exporter configuration completed; Management API policy automation was skipped."
elif [[ "$TLS_ENABLED" == "true" ]]; then
  echo "Check Point L4/L7, Geo, TLS, routing policy, and Log Exporter configuration completed."
else
  echo "Check Point L4/L7, Geo, routing policy, and Log Exporter configuration completed; TLS inspection is disabled."
fi
remove_temporary_restricted_ssh_nsg_rule
trap - EXIT
