#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="$ROOT/infra"
LOCAL_DIR="$ROOT/.local"
TERRAFORM="${TERRAFORM:-terraform}"
TF_PARALLELISM="${TF_PARALLELISM:-1}"

[[ "$TF_PARALLELISM" =~ ^[1-9][0-9]*$ ]] || {
  echo "ERROR: TF_PARALLELISM must be a positive integer." >&2
  exit 1
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ensure_restricted_ssh_nsg_rule() {
  local subscription="$1" resource_group="$2" nsg_id="$3" management_cidr="$4"
  local gateway_nsg_name="${nsg_id##*/}"

  if ! az network nsg rule show \
    --subscription "$subscription" \
    --resource-group "$resource_group" \
    --nsg-name "$gateway_nsg_name" \
    --name AllowRestrictedSSH \
    -o none 2>/dev/null; then
    echo "Restoring the Terraform-managed, source-restricted SSH NSG rule."
    az network nsg rule create \
      --subscription "$subscription" \
      --resource-group "$resource_group" \
      --nsg-name "$gateway_nsg_name" \
      --name AllowRestrictedSSH \
      --priority 100 \
      --direction Inbound \
      --access Allow \
      --protocol Tcp \
      --source-address-prefixes "$management_cidr" \
      --source-port-ranges '*' \
      --destination-address-prefixes '*' \
      --destination-port-ranges 22 \
      --description "Restricted SSH access" \
      --only-show-errors \
      -o none
  fi
}

check_terraform_version() {
  local version major minor
  version="$("$TERRAFORM" version -json | jq -r '.terraform_version')"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  if (( major < 1 || (major == 1 && minor < 9) )); then
    die "Terraform >= 1.9.0 is required; found $version."
  fi
}

resolve_var_file() {
  local input="${1:-}"
  if [[ -z "$input" ]]; then
    printf '%s\n' ""
    return
  fi
  [[ -f "$input" ]] || die "Variable file not found: $input"
  printf '%s/%s\n' "$(cd "$(dirname "$input")" && pwd)" "$(basename "$input")"
}

tfvars_string_value() {
  local file="${1:-}" key="$2"
  [[ -n "$file" && -f "$file" ]] || return 0
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line = $0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      if (match(line, /^"[^"]*"/)) {
        print substr(line, 2, RLENGTH - 2)
        exit
      }
    }
  ' "$file"
}

load_runtime_environment() {
  require_cmd jq
  require_cmd "$TERRAFORM"
  check_terraform_version
}

load_deployment_environment() {
  local var_file="${1:-}" configured_subscription target_subscription
  local sp_tenant sp_client sp_secret

  load_runtime_environment
  require_cmd openssl
  require_cmd az

  configured_subscription="$(tfvars_string_value "$var_file" subscription_id)"
  target_subscription="${configured_subscription:-${TF_VAR_subscription_id:-${ARM_SUBSCRIPTION_ID:-}}}"
  [[ "$target_subscription" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
    die "Set subscription_id in the tfvars file, TF_VAR_subscription_id, or ARM_SUBSCRIPTION_ID."
  az account show --subscription "$target_subscription" --query id -o tsv >/dev/null ||
    die "Azure CLI cannot access subscription $target_subscription. Run az login with an authorized identity."

  export TARGET_SUBSCRIPTION_ID="$target_subscription"
  export TF_VAR_subscription_id="$target_subscription"

  sp_tenant="${TF_VAR_tenant_id:-${ARM_TENANT_ID:-}}"
  sp_client="${TF_VAR_client_id:-${ARM_CLIENT_ID:-}}"
  sp_secret="${TF_VAR_client_secret:-${ARM_CLIENT_SECRET:-}}"
  if [[ -n "$sp_client" || -n "$sp_secret" || -n "$sp_tenant" ]]; then
    [[ -n "$sp_client" && -n "$sp_secret" && -n "$sp_tenant" ]] ||
      die "Service-principal mode requires ARM_TENANT_ID, ARM_CLIENT_ID, and ARM_CLIENT_SECRET together."
    export TF_VAR_tenant_id="$sp_tenant"
    export TF_VAR_client_id="$sp_client"
    export TF_VAR_client_secret="$sp_secret"
  else
    export TF_VAR_tenant_id=""
    export TF_VAR_client_id=""
    export TF_VAR_client_secret=""
  fi

  if [[ -z "${TF_VAR_admin_ssh_public_key:-}" && -f "$HOME/.ssh/id_ed25519.pub" ]]; then
    TF_VAR_admin_ssh_public_key="$(tr -d '\r\n' <"$HOME/.ssh/id_ed25519.pub")"
    export TF_VAR_admin_ssh_public_key
  fi
  : "${TF_VAR_admin_ssh_public_key:?Set TF_VAR_admin_ssh_public_key or create ~/.ssh/id_ed25519.pub.}"

  mkdir -p "$LOCAL_DIR"
  chmod 700 "$LOCAL_DIR"

  if [[ -f "$LOCAL_DIR/deployment-secrets.env" ]]; then
    # This file is generated locally with a hex-only value.
    # shellcheck disable=SC1091
    source "$LOCAL_DIR/deployment-secrets.env"
  fi

  if [[ -z "${TF_VAR_sic_key:-}" ]]; then
    TF_VAR_sic_key="$(openssl rand -hex 24)"
    export TF_VAR_sic_key
    umask 077
    printf 'export TF_VAR_sic_key=%q\n' "$TF_VAR_sic_key" >"$LOCAL_DIR/deployment-secrets.env"
  fi
}

terraform_var_args() {
  local var_file="${1:-}"
  if [[ -n "$var_file" ]]; then
    printf '%s\n' "-var-file=$var_file"
  fi
}

terraform_console_value() {
  local expression="$1"
  local var_file="${2:-}"
  local result

  if [[ -n "$var_file" ]]; then
    result="$(
      printf '%s\n' "$expression" |
        "$TERRAFORM" -chdir="$INFRA" console "-var-file=$var_file"
    )"
  else
    result="$(
      printf '%s\n' "$expression" |
        "$TERRAFORM" -chdir="$INFRA" console
    )"
  fi

  printf '%s\n' "$result" |
    tail -1 |
    sed -e 's/^"//' -e 's/"$//'
}

terraform_output_raw() {
  "$TERRAFORM" -chdir="$INFRA" output -raw "$1"
}
