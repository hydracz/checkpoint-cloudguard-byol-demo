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
RESTRICTED_SSH_RULE_NAME=""

ensure_restricted_ssh_nsg_rules() {
  local subscription="$1" resource_group="$2" nsg_id="$3" management_cidrs_json="$4"
  local gateway_nsg_name="${nsg_id##*/}"
  local cidr
  local -a management_cidrs=()
  local rule_name="AllowRestrictedSSH"

  printf '%s' "$management_cidrs_json" |
    jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' >/dev/null ||
    die "management_cidrs Terraform output must be a non-empty JSON string array."

  while IFS= read -r cidr; do
    management_cidrs+=("$cidr")
  done < <(printf '%s' "$management_cidrs_json" | jq -e -r '.[]')

  if az network nsg rule show \
    --subscription "$subscription" \
    --resource-group "$resource_group" \
    --nsg-name "$gateway_nsg_name" \
    --name "$rule_name" \
    -o none 2>/dev/null; then
    return
  fi

  echo "Restoring Terraform-managed SSH NSG rule $rule_name for configured management CIDRs."
  az network nsg rule create \
    --subscription "$subscription" \
    --resource-group "$resource_group" \
    --nsg-name "$gateway_nsg_name" \
    --name "$rule_name" \
    --priority 100 \
    --direction Inbound \
    --access Allow \
    --protocol Tcp \
    --source-address-prefixes "${management_cidrs[@]}" \
    --source-port-ranges '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges 22 \
    --description "Restricted SSH access from configured management CIDRs" \
    --only-show-errors \
    -o none
  RESTRICTED_SSH_RULE_CREATED=true
  RESTRICTED_SSH_SUBSCRIPTION="$subscription"
  RESTRICTED_SSH_RESOURCE_GROUP="$resource_group"
  RESTRICTED_SSH_NSG_NAME="$gateway_nsg_name"
  RESTRICTED_SSH_RULE_NAME="$rule_name"
}

remove_temporary_restricted_ssh_nsg_rule() {
  if [[ "$RESTRICTED_SSH_RULE_CREATED" == "true" ]]; then
    echo "Removing temporary SSH NSG rule $RESTRICTED_SSH_RULE_NAME."
    if ! az network nsg rule delete \
      --subscription "$RESTRICTED_SSH_SUBSCRIPTION" \
      --resource-group "$RESTRICTED_SSH_RESOURCE_GROUP" \
      --nsg-name "$RESTRICTED_SSH_NSG_NAME" \
      --name "$RESTRICTED_SSH_RULE_NAME" \
      --only-show-errors \
      -o none; then
      echo "ERROR: Failed to remove temporary SSH rule $RESTRICTED_SSH_RULE_NAME from $RESTRICTED_SSH_NSG_NAME." >&2
      return 1
    fi
    RESTRICTED_SSH_RULE_CREATED=false
    RESTRICTED_SSH_RULE_NAME=""
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
  python3 - "$file" "$key" <<'PY'
import json
import re
import sys

path, key = sys.argv[1:]
assignment = re.compile(
    rf"^\s*{re.escape(key)}\s*=\s*(\"(?:\\.|[^\"\\])*\")"
)
with open(path, encoding="utf-8") as tfvars:
    for line in tfvars:
        match = assignment.match(line)
        if match:
            print(json.loads(match.group(1)))
            break
PY
}

validate_checkpoint_admin_password() {
  local password="$1" category_count=0

  ((${#password} >= 8 && ${#password} <= 128)) ||
    die "checkpoint_admin_password must be 8-128 characters."
  [[ "$password" != *'*'* ]] ||
    die "checkpoint_admin_password must not contain '*', which Gaia does not support."
  [[ "$password" != *$'\n'* && "$password" != *$'\r'* ]] ||
    die "checkpoint_admin_password must not contain a newline."
  [[ "$password" =~ [[:lower:]] ]] && ((category_count += 1))
  [[ "$password" =~ [[:upper:]] ]] && ((category_count += 1))
  [[ "$password" =~ [[:digit:]] ]] && ((category_count += 1))
  [[ "$password" =~ [^[:alnum:]] ]] && ((category_count += 1))
  ((category_count >= 3)) ||
    die "checkpoint_admin_password must contain at least three of lowercase, uppercase, number, and special characters."
}

checkpoint_password_matches_hash() {
  local password="$1" password_hash="$2" salt candidate
  local hash_pattern='^\$6\$([A-Za-z0-9./]{2,16})\$[A-Za-z0-9./]{1,86}$'

  [[ "$password_hash" =~ $hash_pattern ]] || return 1
  salt="${BASH_REMATCH[1]}"
  candidate="$(printf '%s' "$password" | openssl passwd -6 -salt "$salt" -stdin)" ||
    return 1
  [[ "$candidate" == "$password_hash" ]]
}

generate_checkpoint_password_hash() {
  local password="$1" password_hash
  local hash_pattern='^\$6\$[A-Za-z0-9./]{2,16}\$[A-Za-z0-9./]{1,86}$'

  password_hash="$(printf '%s' "$password" | openssl passwd -6 -stdin)" ||
    die "OpenSSL cannot generate the SHA-512 crypt hash required by Gaia."
  [[ "$password_hash" =~ $hash_pattern ]] ||
    die "OpenSSL returned an unsupported password hash format."
  printf '%s\n' "$password_hash"
}

deployment_secrets_file() {
  local secrets_file="${CHECKPOINT_DEPLOYMENT_SECRETS_FILE:-$LOCAL_DIR/deployment-secrets.env}"
  if [[ "$secrets_file" == /* ]]; then
    printf '%s\n' "$secrets_file"
  else
    printf '%s/%s\n' "$ROOT" "${secrets_file#./}"
  fi
}

persist_deployment_secrets() {
  local secrets_file
  secrets_file="$(deployment_secrets_file)"
  local temporary_file="${secrets_file}.tmp.$$"

  umask 077
  mkdir -p "$(dirname "$secrets_file")"
  {
    printf 'export TF_VAR_sic_key=%q\n' "$TF_VAR_sic_key"
    if [[ -n "${TF_VAR_checkpoint_admin_password_hash:-}" ]]; then
      printf 'export TF_VAR_checkpoint_admin_password_hash=%q\n' "$TF_VAR_checkpoint_admin_password_hash"
    fi
  } >"$temporary_file"
  chmod 600 "$temporary_file"
  mv "$temporary_file" "$secrets_file"
}

load_runtime_environment() {
  require_cmd jq
  require_cmd "$TERRAFORM"
  check_terraform_version
}

load_terraform_outputs() {
  local outputs_file="${1:-}"

  if [[ -n "$outputs_file" ]]; then
    require_cmd jq
    [[ -f "$outputs_file" ]] || die "Terraform outputs file not found: $outputs_file"
    jq -e '
      type == "object" and
      length > 0 and
      all(.[]; type == "object" and has("value"))
    ' "$outputs_file" >/dev/null ||
      die "Terraform outputs file must contain the JSON object produced by terraform output -json."
    cat "$outputs_file"
  else
    load_runtime_environment
    "$TERRAFORM" -chdir="$INFRA" output -json
  fi
}

load_deployment_environment() {
  local var_file="${1:-}" require_checkpoint_password="${2:-true}"
  local configured_subscription target_subscription
  local configured_admin_password checkpoint_admin_password
  local sp_tenant sp_client sp_secret
  local supplied_public_key private_public_key
  local secrets_file

  load_runtime_environment
  require_cmd openssl
  require_cmd az
  require_cmd python3
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

  secrets_file="$(deployment_secrets_file)"
  if [[ -f "$secrets_file" ]]; then
    # This file is generated locally and contains only the SIC key and password hash.
    # shellcheck disable=SC1091
    source "$secrets_file"
  fi

  if [[ -z "${TF_VAR_sic_key:-}" ]]; then
    TF_VAR_sic_key="$(openssl rand -hex 24)"
    export TF_VAR_sic_key
  fi

  if [[ "$require_checkpoint_password" == "true" ]]; then
    configured_admin_password="$(tfvars_string_value "$var_file" checkpoint_admin_password)"
    checkpoint_admin_password="${configured_admin_password:-${TF_VAR_checkpoint_admin_password:-}}"
    [[ -n "$checkpoint_admin_password" ]] ||
      die "Set checkpoint_admin_password in the tfvars file or TF_VAR_checkpoint_admin_password."
    validate_checkpoint_admin_password "$checkpoint_admin_password"

    if ! checkpoint_password_matches_hash \
      "$checkpoint_admin_password" \
      "${TF_VAR_checkpoint_admin_password_hash:-}"; then
      TF_VAR_checkpoint_admin_password_hash="$(
        generate_checkpoint_password_hash "$checkpoint_admin_password"
      )"
      export TF_VAR_checkpoint_admin_password_hash
    fi
  elif [[ "$require_checkpoint_password" != "false" ]]; then
    die "load_deployment_environment password mode must be true or false."
  fi

  persist_deployment_secrets
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
