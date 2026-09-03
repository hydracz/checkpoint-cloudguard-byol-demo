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

load_deployment_environment "$VAR_FILE" false
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
SYSLOG_QUERY_ERROR="$LOCAL_DIR/azure-query-error.log"
SYSLOG_TABLE_WAIT_SECONDS="${SYSLOG_TABLE_WAIT_SECONDS:-1800}"
SYSLOG_TABLE_RETRY_SECONDS="${SYSLOG_TABLE_RETRY_SECONDS:-30}"

[[ "$SYSLOG_TABLE_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  die "SYSLOG_TABLE_WAIT_SECONDS must be a positive integer."
[[ "$SYSLOG_TABLE_RETRY_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  die "SYSLOG_TABLE_RETRY_SECONDS must be a positive integer."

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
  local record_count
  if ! record_count="$(az monitor log-analytics query \
    --subscription "$SUBSCRIPTION" \
    --workspace "$WORKSPACE" \
    --analytics-query "Syslog | where TimeGenerated > ago(1h) | count" \
    --query '[0].Count' \
    --only-show-errors \
    -o tsv 2>"$SYSLOG_QUERY_ERROR")"; then
    return 1
  fi

  record_count="${record_count//$'\r'/}"
  if [[ ! "$record_count" =~ ^[0-9]+$ ]]; then
    printf 'Azure CLI returned unexpected non-numeric query output: %q\n' \
      "$record_count" >"$SYSLOG_QUERY_ERROR"
    return 1
  fi

  ((record_count > 0))
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
    max_attempts=$(((
      SYSLOG_TABLE_WAIT_SECONDS + SYSLOG_TABLE_RETRY_SECONDS - 1
    ) / SYSLOG_TABLE_RETRY_SECONDS))
    for attempt in $(seq 1 "$max_attempts"); do
      if syslog_table_has_data; then
        table_ready=true
        break
      fi
      if ((attempt % 5 == 0)); then
        echo "Syslog is not queryable yet (${attempt}/${max_attempts}); sending another bootstrap record."
        emit_bootstrap_syslog
      fi
      ((attempt < max_attempts)) && sleep "$SYSLOG_TABLE_RETRY_SECONDS"
    done
    if ! $table_ready; then
      if [[ -s "$SYSLOG_QUERY_ERROR" ]]; then
        echo "Last Azure Log Analytics query error:" >&2
        sed -n '1,12p' "$SYSLOG_QUERY_ERROR" >&2
      fi
      die "Syslog table was not queryable after ${SYSLOG_TABLE_WAIT_SECONDS}s; continuous export was not created. Check the collector VM, Azure Monitor Agent, and DCR association."
    fi
    rm -f "$SYSLOG_QUERY_ERROR"

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

write_terraform_outputs
echo "Continuous Syslog export to the immutable container is enabled."
