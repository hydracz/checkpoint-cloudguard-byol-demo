#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="$ROOT/infra"
LOCAL_DIR="$ROOT/.local"
TERRAFORM="${TERRAFORM:-terraform}"
TF_PARALLELISM="${TF_PARALLELISM:-1}"
DEFAULT_SSH_PRIVATE_KEY="$LOCAL_DIR/checkpoint-demo-ssh"

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

terraform_state_has() {
  local address="$1" state_list
  state_list="$("$TERRAFORM" -chdir="$INFRA" state list 2>/dev/null)" || return 1
  grep -Fqx -- "$address" <<<"$state_list"
}

RESTRICTED_SSH_RULE_CREATED="${RESTRICTED_SSH_RULE_CREATED:-false}"
RESTRICTED_SSH_SUBSCRIPTION=""
RESTRICTED_SSH_RESOURCE_GROUP=""
RESTRICTED_SSH_NSG_NAME=""
RESTRICTED_SSH_RULE_NAMES=()

ensure_restricted_ssh_nsg_rules() {
  local subscription="$1" resource_group="$2" nsg_id="$3" management_cidrs_json="$4"
  local gateway_nsg_name="${nsg_id##*/}"
  local cidr index=0 priority rule_name

  printf '%s' "$management_cidrs_json" |
    jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' >/dev/null ||
    die "management_cidrs Terraform output must be a non-empty JSON string array."

  while IFS= read -r cidr; do
    if ((index == 0)); then
      rule_name="AllowRestrictedSSH"
    else
      printf -v rule_name 'AllowRestrictedSSH%02d' "$((index + 1))"
    fi
    priority=$((100 + (index * 4)))

    if az network nsg rule show \
      --subscription "$subscription" \
      --resource-group "$resource_group" \
      --nsg-name "$gateway_nsg_name" \
      --name "$rule_name" \
      -o none 2>/dev/null; then
      index=$((index + 1))
      continue
    fi

    echo "Restoring Terraform-managed SSH NSG rule $rule_name for $cidr."
    az network nsg rule create \
      --subscription "$subscription" \
      --resource-group "$resource_group" \
      --nsg-name "$gateway_nsg_name" \
      --name "$rule_name" \
      --priority "$priority" \
      --direction Inbound \
      --access Allow \
      --protocol Tcp \
      --source-address-prefixes "$cidr" \
      --source-port-ranges '*' \
      --destination-address-prefixes '*' \
      --destination-port-ranges 22 \
      --description "Restricted SSH access from $cidr" \
      --only-show-errors \
      -o none
    RESTRICTED_SSH_RULE_CREATED=true
    RESTRICTED_SSH_SUBSCRIPTION="$subscription"
    RESTRICTED_SSH_RESOURCE_GROUP="$resource_group"
    RESTRICTED_SSH_NSG_NAME="$gateway_nsg_name"
    RESTRICTED_SSH_RULE_NAMES+=("$rule_name")
    index=$((index + 1))
  done < <(printf '%s' "$management_cidrs_json" | jq -e -r '.[]')
}

remove_temporary_restricted_ssh_nsg_rule() {
  local failed=false rule_name
  if [[ "$RESTRICTED_SSH_RULE_CREATED" == "true" ]]; then
    for rule_name in "${RESTRICTED_SSH_RULE_NAMES[@]}"; do
      echo "Removing temporary SSH NSG rule $rule_name."
      if ! az network nsg rule delete \
        --subscription "$RESTRICTED_SSH_SUBSCRIPTION" \
        --resource-group "$RESTRICTED_SSH_RESOURCE_GROUP" \
        --nsg-name "$RESTRICTED_SSH_NSG_NAME" \
        --name "$rule_name" \
        --only-show-errors \
        -o none; then
        echo "ERROR: Failed to remove temporary SSH rule $rule_name from $RESTRICTED_SSH_NSG_NAME." >&2
        failed=true
      fi
    done
    RESTRICTED_SSH_RULE_CREATED=false
    RESTRICTED_SSH_RULE_NAMES=()
  fi
  if $failed; then
    return 1
  fi
  return 0
}

prepare_repository_ssh_key() {
  local private_key="${CHECKPOINT_SSH_PRIVATE_KEY:-$DEFAULT_SSH_PRIVATE_KEY}"
  local public_key_file="${private_key}.pub"
  local public_key

  if [[ ! -f "$private_key" ]]; then
    [[ ! -e "$private_key" ]] || die "SSH private-key path is not a regular file: $private_key"
    [[ ! -e "$public_key_file" ]] ||
      die "Refusing to overwrite orphaned SSH public key $public_key_file; remove or rename it first."
    umask 077
    ssh-keygen \
      -q \
      -t ed25519 \
      -N "" \
      -C "checkpoint-cloudguard-byol-demo" \
      -f "$private_key"
    echo "Generated repository-local deployment SSH key: $private_key"
  fi

  chmod 600 "$private_key"
  public_key="$(ssh-keygen -y -f "$private_key" | awk '{print $1 " " $2}')" ||
    die "Cannot derive an SSH public key from $private_key."
  printf '%s %s\n' "$public_key" "checkpoint-cloudguard-byol-demo" >"$public_key_file"
  chmod 644 "$public_key_file"

  export CHECKPOINT_SSH_PRIVATE_KEY="$private_key"
  export TF_VAR_admin_ssh_public_key="$public_key checkpoint-cloudguard-byol-demo"
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
  local supplied_public_key private_public_key

  load_runtime_environment
  require_cmd openssl
  require_cmd az
  require_cmd ssh-keygen

  mkdir -p "$LOCAL_DIR"
  chmod 700 "$LOCAL_DIR"

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

  if [[ -z "${TF_VAR_admin_ssh_public_key:-}" ]]; then
    prepare_repository_ssh_key
  elif [[ -n "${CHECKPOINT_SSH_PRIVATE_KEY:-}" ]]; then
    supplied_public_key="$(printf '%s' "$TF_VAR_admin_ssh_public_key" | awk '{print $1 " " $2}')"
    private_public_key="$(ssh-keygen -y -f "$CHECKPOINT_SSH_PRIVATE_KEY" | awk '{print $1 " " $2}')" ||
      die "Cannot derive a public key from CHECKPOINT_SSH_PRIVATE_KEY=$CHECKPOINT_SSH_PRIVATE_KEY."
    [[ "$supplied_public_key" == "$private_public_key" ]] ||
      die "TF_VAR_admin_ssh_public_key does not match CHECKPOINT_SSH_PRIVATE_KEY."
  fi

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
