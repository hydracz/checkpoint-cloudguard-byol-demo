#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

HOURS=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || die "--hours requires an integer."
      HOURS="$2"
      shift 2
      ;;
    *)
      die "Usage: $0 [--hours N]"
      ;;
  esac
done

load_runtime_environment
require_cmd az

SUBSCRIPTION="$(terraform_output_raw subscription_id)"
WORKSPACE="$(terraform_output_raw log_analytics_workspace_customer_id)"
az monitor log-analytics query \
  --subscription "$SUBSCRIPTION" \
  --workspace "$WORKSPACE" \
  --analytics-query "Syslog | where TimeGenerated > ago(${HOURS}h) | where ProcessName has_any ('cp_log_export', 'CheckPoint', 'checkpoint') or SyslogMessage has_any ('action', 'product', 'Check Point') | project TimeGenerated, Computer, Facility, SeverityLevel, SyslogMessage | order by TimeGenerated desc | take 100" \
  -o table
