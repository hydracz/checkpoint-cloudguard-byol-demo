#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="${1:-Standard}"
PACKAGE_JSON="$(mgmt_cli -r true show package name "$PACKAGE_NAME" details-level full --format json)"
ACCESS_LAYER="$(printf '%s' "$PACKAGE_JSON" | jq -e -r '."access-layers"[0].name')"

mgmt_cli -r true show access-rulebase \
  name "$ACCESS_LAYER" \
  limit 500 \
  details-level standard \
  --format json

cp_log_export status
