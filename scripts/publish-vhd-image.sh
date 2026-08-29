#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  publish-vhd-image.sh \
    --archive FILE.tar.gz \
    --subscription UUID \
    --resource-group NAME \
    --location REGION \
    --gallery NAME \
    --definition NAME \
    --version MAJOR.MINOR.PATCH \
    --checkpoint-release R81|R82|R8210 \
    --publisher LABEL \
    --offer LABEL \
    --sku LABEL \
    [--target-region REGION ...] \
    [--plan-publisher NAME --plan-product NAME --plan-name NAME]

Omit all three --plan-* arguments only for an authorized R81 planless image.
R82/R8210 require the exact Check Point Marketplace Plan tuple.
EOF
}

normalize_region() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' '
}

ARCHIVE=""
SUBSCRIPTION=""
RESOURCE_GROUP=""
LOCATION=""
GALLERY=""
DEFINITION=""
VERSION=""
CHECKPOINT_RELEASE=""
PUBLISHER=""
OFFER=""
SKU=""
PLAN_PUBLISHER=""
PLAN_PRODUCT=""
PLAN_NAME=""
TARGET_REGIONS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) ARCHIVE="${2:-}"; shift 2 ;;
    --subscription) SUBSCRIPTION="${2:-}"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="${2:-}"; shift 2 ;;
    --location) LOCATION="${2:-}"; shift 2 ;;
    --gallery) GALLERY="${2:-}"; shift 2 ;;
    --definition) DEFINITION="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --checkpoint-release) CHECKPOINT_RELEASE="${2:-}"; shift 2 ;;
    --publisher) PUBLISHER="${2:-}"; shift 2 ;;
    --offer) OFFER="${2:-}"; shift 2 ;;
    --sku) SKU="${2:-}"; shift 2 ;;
    --target-region) TARGET_REGIONS+=("${2:-}"); shift 2 ;;
    --plan-publisher) PLAN_PUBLISHER="${2:-}"; shift 2 ;;
    --plan-product) PLAN_PRODUCT="${2:-}"; shift 2 ;;
    --plan-name) PLAN_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

for value in ARCHIVE SUBSCRIPTION RESOURCE_GROUP LOCATION GALLERY DEFINITION \
  VERSION CHECKPOINT_RELEASE PUBLISHER OFFER SKU; do
  [[ -n "${!value}" ]] || {
    usage >&2
    die "--$(printf '%s' "$value" | tr '[:upper:]_' '[:lower:]-') is required."
  }
done

[[ -f "$ARCHIVE" ]] || die "Archive not found: $ARCHIVE"
[[ "$SUBSCRIPTION" =~ ^[0-9a-fA-F-]{36}$ ]] || die "--subscription must be an Azure subscription UUID."
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version must use MAJOR.MINOR.PATCH."
[[ "$CHECKPOINT_RELEASE" =~ ^R(81|82|8210)$ ]] ||
  die "--checkpoint-release must be R81, R82, or R8210."

plan_count=0
for value in "$PLAN_PUBLISHER" "$PLAN_PRODUCT" "$PLAN_NAME"; do
  [[ -n "$value" ]] && plan_count=$((plan_count + 1))
done
[[ "$plan_count" -eq 0 || "$plan_count" -eq 3 ]] ||
  die "--plan-publisher, --plan-product, and --plan-name must be supplied together."
if [[ "$CHECKPOINT_RELEASE" == "R81" ]]; then
  [[ "$plan_count" -eq 0 ]] ||
    die "R81 is supported only as an authorized planless image; omit all --plan-* arguments."
else
  case "$CHECKPOINT_RELEASE" in
    R82) expected_plan_product="check-point-cg-r82" ;;
    R8210) expected_plan_product="check-point-cg-r8210" ;;
  esac
  [[ "$plan_count" -eq 3 ]] ||
    die "$CHECKPOINT_RELEASE custom images must supply the Check Point Marketplace Plan."
  [[ "$PLAN_PUBLISHER" == "checkpoint" &&
    "$PLAN_PRODUCT" == "$expected_plan_product" &&
    "$PLAN_NAME" == "mgmt-byol" ]] ||
    die "$CHECKPOINT_RELEASE requires Plan checkpoint:$expected_plan_product:mgmt-byol."
fi

if [[ "${#TARGET_REGIONS[@]}" -eq 0 ]]; then
  TARGET_REGIONS=("$LOCATION")
fi
location_in_targets=false
for region in "${TARGET_REGIONS[@]}"; do
  [[ "$region" =~ ^[a-z0-9]+$ ]] || die "Target region must use an Azure location name without spaces: $region"
  [[ "$region" == "$LOCATION" ]] && location_in_targets=true
done
$location_in_targets || TARGET_REGIONS=("$LOCATION" "${TARGET_REGIONS[@]}")

for command in az azcopy jq tar shasum stat dd od; do
  require_cmd "$command"
done

az account show --subscription "$SUBSCRIPTION" --query id -o tsv >/dev/null ||
  die "Azure CLI cannot access subscription $SUBSCRIPTION in the active cloud."

if [[ -f "$ARCHIVE.sha256" ]]; then
  (
    cd "$(dirname "$ARCHIVE")"
    shasum -a 256 -c "$(basename "$ARCHIVE.sha256")"
  )
fi
archive_sha="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"

member="$(tar -tzf "$ARCHIVE")"
[[ "$(printf '%s\n' "$member" | awk 'END {print NR}')" -eq 1 ]] ||
  die "Archive must contain exactly one file."
[[ "$member" != */* && "$member" == *.vhd ]] ||
  die "Archive member must be a root-level .vhd file."

plan_required=false
definition_tags=(
  "managed-by=publish-vhd-image.sh"
  "checkpoint-release=$CHECKPOINT_RELEASE"
  "marketplace-plan-required=false"
)
if [[ "$plan_count" -eq 3 ]]; then
  plan_required=true
  definition_tags[2]="marketplace-plan-required=true"
fi
version_tags=(
  "${definition_tags[@]}"
  "source-sha256=$archive_sha"
)

if ! az group show \
  --subscription "$SUBSCRIPTION" \
  --name "$RESOURCE_GROUP" \
  -o none 2>/dev/null; then
  az group create \
    --subscription "$SUBSCRIPTION" \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --tags managed-by=publish-vhd-image.sh \
    --only-show-errors \
    -o none
fi

if az sig show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RESOURCE_GROUP" \
  --gallery-name "$GALLERY" \
  -o none 2>/dev/null; then
  gallery_location="$(
    az sig show \
      --subscription "$SUBSCRIPTION" \
      --resource-group "$RESOURCE_GROUP" \
      --gallery-name "$GALLERY" \
      --query location \
      -o tsv
  )"
  [[ "$(normalize_region "$gallery_location")" == "$(normalize_region "$LOCATION")" ]] ||
    die "Existing gallery $GALLERY is in $gallery_location, not $LOCATION."
else
  az sig create \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --location "$LOCATION" \
    --tags managed-by=publish-vhd-image.sh \
    --only-show-errors \
    -o none
fi

definition_args=(
  --subscription "$SUBSCRIPTION"
  --resource-group "$RESOURCE_GROUP"
  --gallery-name "$GALLERY"
  --gallery-image-definition "$DEFINITION"
  --location "$LOCATION"
  --publisher "$PUBLISHER"
  --offer "$OFFER"
  --sku "$SKU"
  --os-type Linux
  --os-state Generalized
  --hyper-v-generation V1
  --architecture x64
  --minimum-cpu-core 8
  --minimum-memory 32
  --tags "${definition_tags[@]}"
  --only-show-errors
)
if $plan_required; then
  definition_args+=(
    --plan-publisher "$PLAN_PUBLISHER"
    --plan-product "$PLAN_PRODUCT"
    --plan-name "$PLAN_NAME"
  )
fi

if ! az sig image-definition show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RESOURCE_GROUP" \
  --gallery-name "$GALLERY" \
  --gallery-image-definition "$DEFINITION" \
  -o none 2>/dev/null; then
  az sig image-definition create "${definition_args[@]}" -o none
fi

definition_json="$(
  az sig image-definition show \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --gallery-image-definition "$DEFINITION" \
    -o json
)"
jq -e \
  --arg release "$CHECKPOINT_RELEASE" \
  --argjson plan_required "$plan_required" \
  --arg plan_publisher "$PLAN_PUBLISHER" \
  --arg plan_product "$PLAN_PRODUCT" \
  --arg plan_name "$PLAN_NAME" '
    .osType == "Linux" and
    .osState == "Generalized" and
    .hyperVGeneration == "V1" and
    .architecture == "x64" and
    .tags["checkpoint-release"] == $release and
    .tags["marketplace-plan-required"] == ($plan_required | tostring) and
    (if $plan_required then
       .purchasePlan.publisher == $plan_publisher and
       .purchasePlan.product == $plan_product and
       .purchasePlan.name == $plan_name
     else
       (.purchasePlan == null)
     end)
  ' <<<"$definition_json" >/dev/null ||
  die "Existing image definition metadata does not match the requested release and Plan mode."

if version_json="$(
  az sig image-version show \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --gallery-image-definition "$DEFINITION" \
    --gallery-image-version "$VERSION" \
    --expand ReplicationStatus \
    -o json 2>/dev/null
)"; then
  jq -e \
    --arg sha "$archive_sha" '
      .provisioningState == "Succeeded" and
      .replicationStatus.aggregatedState == "Completed" and
      .tags["source-sha256"] == $sha
    ' <<<"$version_json" >/dev/null ||
    die "Existing image version is incomplete or was built from a different archive."
  for region in "${TARGET_REGIONS[@]}"; do
    normalized_region="$(normalize_region "$region")"
    jq -e \
      --arg region "$normalized_region" '
        any(.replicationStatus.summary[];
          (.region | ascii_downcase | gsub(" "; "")) == $region and
          .state == "Completed")
      ' <<<"$version_json" >/dev/null ||
      die "Existing image version is not replicated to requested region $region."
  done
  jq -r '.id' <<<"$version_json"
  exit 0
fi

safe_version="${VERSION//./-}"
upload_disk="${DEFINITION}-${safe_version}-upload"
managed_image="${DEFINITION}-${safe_version}-source"

for resource in \
  "disk:$upload_disk" \
  "image:$managed_image"; do
  resource_type="${resource%%:*}"
  resource_name="${resource#*:}"
  if az "$resource_type" show \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$resource_name" \
    -o none 2>/dev/null; then
    die "Intermediate $resource_type already exists: $resource_name. Remove it after verifying it belongs to this failed publication, then retry."
  fi
done

mkdir -p "$LOCAL_DIR"
work_dir="$(mktemp -d "$LOCAL_DIR/image-publish.XXXXXX")"
disk_access_granted=false
cleanup() {
  if $disk_access_granted; then
    az disk revoke-access \
      --subscription "$SUBSCRIPTION" \
      --resource-group "$RESOURCE_GROUP" \
      --name "$upload_disk" \
      --only-show-errors \
      -o none >/dev/null 2>&1 || true
  fi
  case "$work_dir" in
    "$LOCAL_DIR"/image-publish.*) rm -rf -- "$work_dir" ;;
  esac
}
trap cleanup EXIT

echo "Extracting and validating $member..."
tar -xzf "$ARCHIVE" -C "$work_dir" "$member"
vhd_path="$work_dir/$member"
if stat -f %z "$vhd_path" >/dev/null 2>&1; then
  vhd_size="$(stat -f %z "$vhd_path")"
else
  vhd_size="$(stat -c %s "$vhd_path")"
fi
[[ "$vhd_size" -gt 0 && $((vhd_size % 512)) -eq 0 ]] ||
  die "VHD size must be positive and 512-byte aligned."
footer_cookie="$(dd if="$vhd_path" bs=1 skip=$((vhd_size - 512)) count=8 2>/dev/null)"
[[ "$footer_cookie" == "conectix" ]] || die "VHD fixed-disk footer was not found."
disk_type="$(
  dd if="$vhd_path" bs=1 skip=$((vhd_size - 512 + 60)) count=4 2>/dev/null |
    od -An -tx1 |
    tr -d ' \n'
)"
[[ "$disk_type" == "00000002" ]] ||
  die "VHD disk type must be Fixed (2); footer contains type 0x$disk_type."

az disk create \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$upload_disk" \
  --location "$LOCATION" \
  --upload-type Upload \
  --upload-size-bytes "$vhd_size" \
  --sku Standard_LRS \
  --os-type Linux \
  --hyper-v-generation V1 \
  --tags "${version_tags[@]}" \
  --only-show-errors \
  -o none

grant="$(
  az disk grant-access \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$upload_disk" \
    --duration-in-seconds 14400 \
    --access-level Write \
    --only-show-errors \
    -o json
)"
target_sas="$(jq -e -r '.accessSAS // .accessSas' <<<"$grant")"
disk_access_granted=true
export AZCOPY_LOG_LOCATION="$work_dir/azcopy-logs"
export AZCOPY_JOB_PLAN_LOCATION="$work_dir/azcopy-jobs"
mkdir -p "$AZCOPY_LOG_LOCATION" "$AZCOPY_JOB_PLAN_LOCATION"

echo "Uploading fixed VHD to managed disk $upload_disk..."
azcopy copy \
  "$vhd_path" \
  "$target_sas" \
  --from-to LocalBlob \
  --blob-type PageBlob \
  --overwrite=true \
  --check-length=true \
  --log-level ERROR \
  --output-level essential

az disk revoke-access \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$upload_disk" \
  --only-show-errors \
  -o none
disk_access_granted=false

disk_id="$(
  az disk show \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$upload_disk" \
    --query id \
    -o tsv
)"
az image create \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$managed_image" \
  --location "$LOCATION" \
  --source "$disk_id" \
  --os-type Linux \
  --hyper-v-generation V1 \
  --storage-sku Standard_LRS \
  --tags "${version_tags[@]}" \
  --only-show-errors \
  -o none

managed_image_id="$(
  az image show \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$managed_image" \
    --query id \
    -o tsv
)"
target_region_args=()
for region in "${TARGET_REGIONS[@]}"; do
  target_region_args+=("${region}=1=standard_lrs")
done

echo "Publishing Compute Gallery image version $DEFINITION/$VERSION..."
az sig image-version create \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RESOURCE_GROUP" \
  --gallery-name "$GALLERY" \
  --gallery-image-definition "$DEFINITION" \
  --gallery-image-version "$VERSION" \
  --location "$LOCATION" \
  --managed-image "$managed_image_id" \
  --target-regions "${target_region_args[@]}" \
  --replica-count 1 \
  --storage-account-type Standard_LRS \
  --tags "${version_tags[@]}" \
  --only-show-errors \
  -o none

version_json="$(
  az sig image-version show \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY" \
    --gallery-image-definition "$DEFINITION" \
    --gallery-image-version "$VERSION" \
    --expand ReplicationStatus \
    -o json
)"
jq -e '
  .provisioningState == "Succeeded" and
  .replicationStatus.aggregatedState == "Completed" and
  all(.replicationStatus.summary[]; .state == "Completed")
' <<<"$version_json" >/dev/null ||
  die "Image version was created but replication is not complete."

jq -r '.id' <<<"$version_json"
