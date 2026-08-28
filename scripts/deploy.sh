#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

VAR_FILE=""
SKIP_POLICY=false
LOCK_WORM=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --var-file)
      [[ $# -ge 2 ]] || die "--var-file requires a path."
      VAR_FILE="$(resolve_var_file "$2")"
      shift 2
      ;;
    --skip-policy)
      SKIP_POLICY=true
      shift
      ;;
    --lock-worm)
      LOCK_WORM=true
      shift
      ;;
    *)
      die "Usage: $0 [--var-file FILE] [--skip-policy] [--lock-worm]"
      ;;
  esac
done

load_deployment_environment "$VAR_FILE"
require_cmd az

audit_auto_vars="$INFRA/audit.auto.tfvars.json"
if "$TERRAFORM" -chdir="$INFRA" state list 2>/dev/null |
  grep -q 'azurerm_log_analytics_data_export_rule.syslog'; then
  printf '{"enable_log_data_export":true}\n' >"$audit_auto_vars"
else
  rm -f "$audit_auto_vars"
fi

var_args=()
if [[ -n "$VAR_FILE" ]]; then
  var_args+=(--var-file "$VAR_FILE")
fi

"$ROOT/scripts/preflight.sh" "${var_args[@]}"

offer="$(terraform_console_value local.checkpoint_offer "$VAR_FILE")"
plan="$(terraform_console_value local.checkpoint_plan "$VAR_FILE")"
echo "Accepting Azure Marketplace terms for checkpoint:$offer:$plan..."
az vm image terms accept \
  --publisher checkpoint \
  --offer "$offer" \
  --plan "$plan" \
  --subscription "$TARGET_SUBSCRIPTION_ID" \
  --only-show-errors \
  -o none

"$ROOT/scripts/plan.sh" "${var_args[@]}"
"$TERRAFORM" -chdir="$INFRA" apply -input=false -auto-approve -parallelism="$TF_PARALLELISM" "$LOCAL_DIR/plan.tfplan"
"$TERRAFORM" -chdir="$INFRA" output -json >"$LOCAL_DIR/latest-deployment-outputs.json"

if ! $SKIP_POLICY; then
  "$ROOT/scripts/configure-policy.sh"
fi

"$ROOT/scripts/enable-audit-export.sh" "${var_args[@]}"

if $LOCK_WORM; then
  "$ROOT/scripts/lock-worm.sh" --yes
fi

echo "Deployment complete. Outputs: $LOCAL_DIR/latest-deployment-outputs.json"
