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
custom_image_id="$(terraform_console_value var.checkpoint_image_id "$VAR_FILE")"
custom_image_requires_plan="$(terraform_console_value var.checkpoint_image_requires_plan "$VAR_FILE")"
checkpoint_os_version="$(terraform_console_value var.checkpoint_os_version "$VAR_FILE")"
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

normalize_region() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' '
}

validate_custom_image() {
  local image_id="$1" target_location="$2" requires_plan="$3" expected_release="$4"
  local lower_id definition_id
  local definition_json version_json versions_json image_json metadata
  local os_state os_type generation architecture plan_publisher plan_product plan_name image_location
  local image_release plan_required_tag normalized_target

  lower_id="$(printf '%s' "$image_id" | tr '[:upper:]' '[:lower:]')"
  normalized_target="$(normalize_region "$target_location")"

  case "$lower_id" in
    */providers/microsoft.compute/galleries/*/images/*)
      if [[ "$lower_id" == */versions/* ]]; then
        definition_id="$(printf '%s' "$image_id" |
          sed -E 's#/([Vv][Ee][Rr][Ss][Ii][Oo][Nn][Ss])/[^/]+$##')"
      else
        definition_id="$image_id"
      fi

      definition_json="$(az_query_with_retry az resource show \
        --ids "$definition_id" \
        --api-version 2024-03-03 \
        -o json)" ||
        die "Cannot read Compute Gallery image definition $definition_id."

      metadata="$(jq -r '[
        .properties.osState // "",
        .properties.osType // "",
        .properties.hyperVGeneration // "",
        .properties.architecture // "",
        .properties.purchasePlan.publisher // "",
        .properties.purchasePlan.product // "",
        .properties.purchasePlan.name // "",
        .tags["checkpoint-release"] // "",
        .tags["marketplace-plan-required"] // ""
      ] | join("\u001f")' <<<"$definition_json")"
      IFS=$'\x1f' read -r os_state os_type generation architecture plan_publisher plan_product plan_name image_release plan_required_tag <<<"$metadata"

      [[ "$os_state" == "Generalized" ]] ||
        die "checkpoint_image_id must reference a Generalized image; found $os_state."
      [[ "$os_type" == "Linux" ]] ||
        die "checkpoint_image_id must reference a Linux image; found $os_type."
      [[ "$generation" == "V1" ]] ||
        die "checkpoint_image_id must reference a Gen1 image for standalone mgmt-byol; found $generation."
      [[ -z "$architecture" || "$architecture" == "x64" ]] ||
        die "checkpoint_image_id must reference an x64 image; found $architecture."
      if [[ "$requires_plan" == "true" ]]; then
        [[ "$plan_publisher" == "checkpoint" && "$plan_product" == "$offer" && "$plan_name" == "$plan" ]] ||
          die "Compute Gallery image definition must retain purchase plan checkpoint:$offer:$plan."
      else
        [[ -z "$plan_publisher" && -z "$plan_product" && -z "$plan_name" ]] ||
          die "checkpoint_image_requires_plan=false requires a Compute Gallery image definition without purchasePlan metadata."
      fi
      [[ -z "$image_release" || "$image_release" == "$expected_release" ]] ||
        die "Compute Gallery image is tagged for $image_release, but checkpoint_os_version is $expected_release."
      [[ -z "$plan_required_tag" || "$plan_required_tag" == "$requires_plan" ]] ||
        die "Compute Gallery image plan tag is $plan_required_tag, but checkpoint_image_requires_plan is $requires_plan."

      if [[ "$lower_id" == */versions/* ]]; then
        version_json="$(az_query_with_retry az resource show \
          --ids "$image_id" \
          --api-version 2024-03-03 \
          -o json)" ||
          die "Cannot read Compute Gallery image version $image_id."
        jq -e \
          --arg target "$normalized_target" \
          '.properties.provisioningState == "Succeeded" and
           any(.properties.publishingProfile.targetRegions[]?;
             (.name | ascii_downcase | gsub(" "; "")) == $target)' \
          <<<"$version_json" >/dev/null ||
          die "Compute Gallery image version is not ready in $target_location."
      else
        versions_json="$(az_query_with_retry az rest \
          --method get \
          --url "https://management.azure.com${definition_id}/versions?api-version=2024-03-03")" ||
          die "Cannot list versions for Compute Gallery image definition $definition_id."
        jq -e \
          --arg target "$normalized_target" \
          'any(.value[]?;
             .properties.provisioningState == "Succeeded" and
             .properties.publishingProfile.excludeFromLatest != true and
             any(.properties.publishingProfile.targetRegions[]?;
               (.name | ascii_downcase | gsub(" "; "")) == $target))' \
          <<<"$versions_json" >/dev/null ||
          die "Compute Gallery image definition has no deployable latest version in $target_location."
      fi
      ;;
    */providers/microsoft.compute/images/*)
      image_json="$(az_query_with_retry az image show --ids "$image_id" -o json)" ||
        die "Cannot read managed image $image_id."
      metadata="$(jq -r '[
        .storageProfile.osDisk.osState // "",
        .storageProfile.osDisk.osType // "",
        .hyperVGeneration // "",
        .location // "",
        .tags["checkpoint-release"] // "",
        .tags["marketplace-plan-required"] // ""
      ] | join("\u001f")' <<<"$image_json")"
      IFS=$'\x1f' read -r os_state os_type generation image_location image_release plan_required_tag <<<"$metadata"

      [[ "$os_state" == "Generalized" ]] ||
        die "checkpoint_image_id must reference a Generalized image; found $os_state."
      [[ "$os_type" == "Linux" ]] ||
        die "checkpoint_image_id must reference a Linux image; found $os_type."
      [[ "$generation" == "V1" ]] ||
        die "checkpoint_image_id must reference a Gen1 image for standalone mgmt-byol; found $generation."
      [[ "$(normalize_region "$image_location")" == "$normalized_target" ]] ||
        die "Managed image is in $image_location, but the gateway location is $target_location."
      [[ -z "$image_release" || "$image_release" == "$expected_release" ]] ||
        die "Managed image is tagged for $image_release, but checkpoint_os_version is $expected_release."
      [[ -z "$plan_required_tag" || "$plan_required_tag" == "$requires_plan" ]] ||
        die "Managed image plan tag is $plan_required_tag, but checkpoint_image_requires_plan is $requires_plan."
      ;;
    *)
      die "Unsupported checkpoint_image_id resource type: $image_id"
      ;;
  esac
}

checked_skus="|"
check_size_available() {
  local region="$1" size="$2" role="$3" found
  [[ "$checked_skus" == *"|$region:$size|"* ]] && return 0
  if ! found="$(az_query_with_retry az vm list-sizes \
      --subscription "$TARGET_SUBSCRIPTION_ID" \
      --location "$region" \
      --query "[?name=='$size'].name | [0]" \
      -o tsv)"; then
    echo "WARNING: Azure SKU query failed after retries for $region; Terraform plan will perform the authoritative check." >&2
    return 0
  fi
  [[ "$found" == "$size" ]] || die "$role size $size is unavailable in $region for subscription $TARGET_SUBSCRIPTION_ID."
  checked_skus+="$region:$size|"
}

check_size_available "$location" "$checkpoint_size" "Check Point"
check_size_available "$location" "$workload_size" "Primary workload"
check_size_available "$remote_location" "$workload_size" "Remote workload"
check_size_available "$location" "$collector_size" "Collector"

if [[ -n "$custom_image_id" ]]; then
  validate_custom_image "$custom_image_id" "$location" "$custom_image_requires_plan" "$checkpoint_os_version"
  image_urn="$custom_image_id"
else
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
fi

echo "Preflight passed for subscription $TARGET_SUBSCRIPTION_ID, image $image_urn, and requested VM sizes. No Azure resources were created."
