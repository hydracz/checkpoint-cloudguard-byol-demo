#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

VAR_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --var-file)
      [[ $# -ge 2 ]] || die "--var-file requires a path."
      VAR_FILE="$(resolve_var_file "$2")"
      shift 2
      ;;
    *)
      die "Usage: $0 [--var-file FILE]"
      ;;
  esac
done

load_deployment_environment "$VAR_FILE"
require_cmd az

"$ROOT/scripts/verify-vendor.sh"

"$TERRAFORM" -chdir="$INFRA" fmt -recursive -check
"$TERRAFORM" -chdir="$INFRA" init -backend=false -input=false
"$TERRAFORM" -chdir="$INFRA" validate
"$TERRAFORM" -chdir="$INFRA" test
"$ROOT/tests/validate-repo.sh"

offer="$(terraform_console_value local.checkpoint_offer "$VAR_FILE")"
plan="$(terraform_console_value local.checkpoint_plan "$VAR_FILE")"
location="$(terraform_console_value var.location "$VAR_FILE")"
remote_location="$(terraform_console_value var.remote_location "$VAR_FILE")"
checkpoint_size="$(terraform_console_value var.checkpoint_vm_size "$VAR_FILE")"
workload_size="$(terraform_console_value var.workload_vm_size "$VAR_FILE")"
collector_size="$(terraform_console_value var.collector_vm_size "$VAR_FILE")"

az_query_with_retry() {
  local attempt output
  for attempt in 1 2 3; do
    if output="$("$@" 2>"$LOCAL_DIR/azure-query-error.log")"; then
      printf '%s' "$output"
      return 0
    fi
    sleep $((attempt * 5))
  done
  return 1
}

check_size_available() {
  local region="$1" size="$2" role="$3" found
  if ! found="$(az_query_with_retry az vm list-sizes \
      --subscription "$TARGET_SUBSCRIPTION_ID" \
      --location "$region" \
      --query "[?name=='$size'].name | [0]" \
      -o tsv)"; then
    echo "WARNING: Azure SKU query failed after retries for $region; Terraform plan will perform the authoritative check." >&2
    return 0
  fi
  [[ "$found" == "$size" ]] || die "$role size $size is unavailable in $region for subscription $TARGET_SUBSCRIPTION_ID."
}

check_size_available "$location" "$checkpoint_size" "Check Point"
check_size_available "$location" "$workload_size" "Primary workload"
check_size_available "$remote_location" "$workload_size" "Remote workload"
check_size_available "$location" "$collector_size" "Collector"

if image_urn="$(az_query_with_retry az vm image list \
    --subscription "$TARGET_SUBSCRIPTION_ID" \
    --location "$location" \
    --publisher checkpoint \
    --offer "$offer" \
    --sku "$plan" \
    --all \
    --query '[0].urn' \
    -o tsv)"; then
  [[ -n "$image_urn" ]] || die "Marketplace image checkpoint:$offer:$plan is unavailable in $location."
  if image_generation="$(az_query_with_retry az vm image show \
      --subscription "$TARGET_SUBSCRIPTION_ID" \
      --location "$location" \
      --urn "$image_urn" \
      --query hyperVGeneration \
      -o tsv)"; then
    [[ "$image_generation" == "V1" ]] || die "Expected the standalone mgmt-byol image to be Gen1; found $image_generation."
  else
    echo "WARNING: Azure image-generation query failed after retries; Terraform plan will perform the authoritative image check." >&2
  fi
else
  echo "WARNING: Azure Marketplace image query failed after retries; Terraform plan will perform the authoritative image check." >&2
  image_urn="checkpoint:$offer:$plan:latest"
fi

echo "Preflight passed for subscription $TARGET_SUBSCRIPTION_ID, image $image_urn, and requested VM sizes. No Azure resources were created."
