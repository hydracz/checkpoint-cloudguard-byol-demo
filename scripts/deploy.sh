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
if terraform_state_has 'azurerm_log_analytics_data_export_rule.syslog[0]'; then
  printf '{"enable_log_data_export":true}\n' >"$audit_auto_vars"
else
  rm -f "$audit_auto_vars"
fi

if [[ -n "$VAR_FILE" ]]; then
  "$ROOT/scripts/preflight.sh" --var-file "$VAR_FILE"
else
  "$ROOT/scripts/preflight.sh"
fi

offer="$(terraform_console_value local.checkpoint_offer "$VAR_FILE")"
plan="$(terraform_console_value local.checkpoint_plan "$VAR_FILE")"
source_requires_plan="$(terraform_console_value local.checkpoint_source_requires_plan "$VAR_FILE")"
if [[ "$source_requires_plan" == "true" ]]; then
  echo "Accepting Azure Marketplace terms for checkpoint:$offer:$plan..."
  az vm image terms accept \
    --publisher checkpoint \
    --offer "$offer" \
    --plan "$plan" \
    --subscription "$TARGET_SUBSCRIPTION_ID" \
    --only-show-errors \
    -o none
else
  echo "Using a custom image without Marketplace purchase plan metadata."
fi

if [[ -n "$VAR_FILE" ]]; then
  "$ROOT/scripts/plan.sh" --var-file "$VAR_FILE"
else
  "$ROOT/scripts/plan.sh"
fi
"$TERRAFORM" -chdir="$INFRA" apply -input=false -auto-approve -parallelism="$TF_PARALLELISM" "$LOCAL_DIR/plan.tfplan"
"$TERRAFORM" -chdir="$INFRA" output -json >"$LOCAL_DIR/latest-deployment-outputs.json"

if $SKIP_POLICY; then
  CHECKPOINT_SKIP_POLICY_CONFIGURATION=true "$ROOT/scripts/configure-policy.sh"
else
  "$ROOT/scripts/configure-policy.sh"
fi

if [[ -n "$VAR_FILE" ]]; then
  "$ROOT/scripts/enable-audit-export.sh" --var-file "$VAR_FILE"
else
  "$ROOT/scripts/enable-audit-export.sh"
fi

if $LOCK_WORM; then
  "$ROOT/scripts/lock-worm.sh" --yes
fi

echo "Deployment complete. Outputs: $LOCAL_DIR/latest-deployment-outputs.json"
