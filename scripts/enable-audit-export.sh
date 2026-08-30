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

SUBSCRIPTION="$(terraform_output_raw subscription_id)"
RG="$(terraform_output_raw resource_group_name)"
COLLECTOR_VM="$(terraform_output_raw collector_vm_name)"
WORKSPACE="$(terraform_output_raw log_analytics_workspace_customer_id)"
WORKSPACE_RESOURCE_ID="$(terraform_output_raw log_analytics_workspace_id)"
DESTINATION_RESOURCE_ID="$(terraform_output_raw audit_storage_account_id)"
EXPORT_NAME="$(terraform_output_raw log_analytics_data_export_name)"
EXPORT_ID="$WORKSPACE_RESOURCE_ID/dataExports/$EXPORT_NAME"
AUTO_VARS="$INFRA/audit.auto.tfvars.json"

emit_bootstrap_syslog() {
  az vm run-command invoke \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RG" \
    --name "$COLLECTOR_VM" \
    --command-id RunShellScript \
    --scripts "logger -p user.info 'checkpoint-demo-syslog-table-bootstrap'" \
    --only-show-errors \
    -o none
}

syslog_table_has_data() {
  local result
  if ! result="$(az monitor log-analytics query \
    --subscription "$SUBSCRIPTION" \
    --workspace "$WORKSPACE" \
    --analytics-query "Syslog | where TimeGenerated > ago(1h) | take 1" \
    --only-show-errors \
    -o json 2>/dev/null)"; then
    return 1
  fi
  printf '%s' "$result" |
    jq -e '
      if type == "array" then length > 0
      elif (.tables? | type) == "array" then (.tables[0].rows | length) > 0
      else false
      end
    ' >/dev/null
}

apply_export_configuration() {
  if [[ -n "$VAR_FILE" ]]; then
    "$ROOT/scripts/plan.sh" --var-file "$VAR_FILE"
  else
    "$ROOT/scripts/plan.sh"
  fi
  "$TERRAFORM" -chdir="$INFRA" apply \
    -input=false \
    -auto-approve \
    -parallelism="$TF_PARALLELISM" \
    "$LOCAL_DIR/plan.tfplan"
}

if ! terraform_state_has 'azurerm_log_analytics_data_export_rule.syslog[0]'; then
  existing_export="$(
    az resource show \
      --subscription "$SUBSCRIPTION" \
      --ids "$EXPORT_ID" \
      --api-version 2020-08-01 \
      -o json 2>/dev/null || true
  )"
  if [[ -n "$existing_export" ]]; then
    existing_destination="$(
      printf '%s' "$existing_export" |
        jq -r '.properties.destination.resourceId // ""'
    )"
    normalized_existing_destination="$(printf '%s' "$existing_destination" | tr '[:upper:]' '[:lower:]')"
    normalized_destination="$(printf '%s' "$DESTINATION_RESOURCE_ID" | tr '[:upper:]' '[:lower:]')"
    if [[ "$normalized_existing_destination" == "$normalized_destination" ]]; then
      echo "Importing the existing matching Log Analytics data export into Terraform state."
      printf '{"enable_log_data_export":true}\n' >"$AUTO_VARS"
      if [[ -n "$VAR_FILE" ]]; then
        "$TERRAFORM" -chdir="$INFRA" import \
          -input=false \
          "-var-file=$VAR_FILE" \
          'azurerm_log_analytics_data_export_rule.syslog[0]' \
          "$EXPORT_ID"
      else
        "$TERRAFORM" -chdir="$INFRA" import \
          -input=false \
          'azurerm_log_analytics_data_export_rule.syslog[0]' \
          "$EXPORT_ID"
      fi
      apply_export_configuration
    else
      echo "Deleting a stale recovered data export that targets a different storage account."
      az resource delete \
        --subscription "$SUBSCRIPTION" \
        --ids "$EXPORT_ID" \
        --api-version 2020-08-01
      for attempt in $(seq 1 30); do
        if ! az resource show \
          --subscription "$SUBSCRIPTION" \
          --ids "$EXPORT_ID" \
          --api-version 2020-08-01 \
          -o none 2>/dev/null; then
          break
        fi
        ((attempt < 30)) || die "The stale Log Analytics data export was not deleted within 5 minutes."
        sleep 10
      done
      existing_export=""
    fi
  fi

  if [[ -z "$existing_export" ]]; then
    echo "Waiting for Azure Monitor Agent to create the Syslog table..."
    emit_bootstrap_syslog
    table_ready=false
    for attempt in $(seq 1 30); do
      if syslog_table_has_data; then
        table_ready=true
        break
      fi
      if ((attempt % 5 == 0)); then
        emit_bootstrap_syslog
      fi
      sleep 30
    done
    $table_ready || die "Syslog table was not queryable after 15 minutes; continuous export was not created."

    printf '{"enable_log_data_export":true}\n' >"$AUTO_VARS"
    apply_export_configuration
  fi
else
  printf '{"enable_log_data_export":true}\n' >"$AUTO_VARS"
fi

az vm run-command invoke \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RG" \
  --name "$COLLECTOR_VM" \
  --command-id RunShellScript \
  --scripts "logger -p user.info 'checkpoint-demo-export-enabled'" \
  --only-show-errors \
  -o none

"$TERRAFORM" -chdir="$INFRA" output -json >"$LOCAL_DIR/latest-deployment-outputs.json"
echo "Continuous Syslog export to the immutable container is enabled."
