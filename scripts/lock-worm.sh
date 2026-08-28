#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      YES=true
      shift
      ;;
    *)
      die "Usage: $0 --yes"
      ;;
  esac
done

$YES || die "Refusing irreversible WORM lock. Re-run with --yes after reviewing retention."
load_runtime_environment
require_cmd az

SUBSCRIPTION="$(terraform_output_raw subscription_id)"
RG="$(terraform_output_raw resource_group_name)"
ACCOUNT="$(terraform_output_raw audit_storage_account_name)"
CONTAINER="$(terraform_output_raw audit_container_name)"
RETENTION="$(terraform_output_raw immutable_retention_days)"

policy_json="$(az storage container immutability-policy show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RG" \
  --account-name "$ACCOUNT" \
  --container-name "$CONTAINER" \
  -o json)"
state="$(printf '%s' "$policy_json" | jq -r '.state // .immutabilityPolicy.state // empty')"
state_lower="$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
if [[ "$state_lower" == "locked" ]]; then
  echo "$ACCOUNT/$CONTAINER is already locked for immutable retention."
  exit 0
fi

etag="$(printf '%s' "$policy_json" | jq -r '.etag // empty')"
[[ -n "$etag" ]] || die "Unable to read the current immutability policy ETag."

az storage container immutability-policy lock \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RG" \
  --account-name "$ACCOUNT" \
  --container-name "$CONTAINER" \
  --if-match "$etag" \
  --only-show-errors \
  -o none

echo "Locked $ACCOUNT/$CONTAINER for $RETENTION days. This cannot be undone or shortened."
