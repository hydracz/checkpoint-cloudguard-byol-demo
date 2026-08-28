#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

load_runtime_environment
require_cmd az
require_cmd python3

outputs="$("$TERRAFORM" -chdir="$INFRA" output -json)"
output_value() {
  printf '%s' "$outputs" | jq -r --arg key "$1" '
    if has($key) then .[$key].value
    else error("missing Terraform output: " + $key)
    end
  '
}

SUBSCRIPTION="$(output_value subscription_id)"
COMPANY_DOMAIN="$(output_value company_domain)"
RG="$(output_value resource_group_name)"
GATEWAY_VM="$(output_value checkpoint_vm_name)"
PACKAGE_NAME="$(output_value policy_package_name)"
EU_VM="$(output_value eu_workload_vm_name)"
REMOTE_VM="$(output_value remote_workload_vm_name)"
EU_IP="$(output_value eu_workload_private_ip)"
REMOTE_IP="$(output_value remote_workload_private_ip)"
EU_NIC="$(output_value eu_workload_nic_name)"
REMOTE_NIC="$(output_value remote_workload_nic_name)"
NEXT_HOP="$(output_value checkpoint_backend_private_ip)"
TLS_ENABLED="$(output_value enable_tls_inspection)"
INBOUND_ENABLED="$(output_value enable_inbound_demo)"
PUBLIC_IP="$(output_value checkpoint_public_ip)"
WORKSPACE="$(output_value log_analytics_workspace_customer_id)"
ACCOUNT="$(output_value audit_storage_account_name)"
CONTAINER="$(output_value audit_container_name)"
RETENTION="$(output_value immutable_retention_days)"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$ROOT/evidence/$STAMP"
mkdir -p "$OUT"

RESULTS=()
record() {
  RESULTS+=("$1|$2|$3")
}

validate_default_route() {
  local file="$1"
  python3 - "$file" "$NEXT_HOP" <<'PY'
import json
import sys

routes = json.load(open(sys.argv[1], encoding="utf-8")).get("value", [])
next_hop = sys.argv[2]
matches = [
    route
    for route in routes
    if "0.0.0.0/0" in route.get("addressPrefix", [])
    and route.get("nextHopType") == "VirtualAppliance"
    and next_hop in route.get("nextHopIpAddress", [])
    and route.get("state") == "Active"
]
raise SystemExit(0 if matches else 1)
PY
}

for route_case in "T01:$EU_NIC" "T02:$REMOTE_NIC"; do
  case_id="${route_case%%:*}"
  nic="${route_case#*:}"
  evidence="$OUT/${case_id}-effective-routes.json"
  if az network nic show-effective-route-table \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RG" \
    --name "$nic" \
    -o json >"$evidence" 2>&1 &&
    validate_default_route "$evidence"; then
    record "$case_id" PASS "$(basename "$evidence")"
  else
    record "$case_id" FAIL "$(basename "$evidence")"
  fi
done

run_vm_case() {
  local case_id="$1" vm="$2" peer_ip="$3"
  peer_ip="${peer_ip:--}"
  local evidence="$OUT/${case_id}-${vm}.json"
  local status
  if az vm run-command invoke \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RG" \
    --name "$vm" \
    --command-id RunShellScript \
    --scripts @"$ROOT/scripts/vm-case.sh" \
    --parameters "$case_id" "$peer_ip" "$TLS_ENABLED" "$COMPANY_DOMAIN" \
    --only-show-errors \
    -o json >"$evidence" 2>&1; then
    status="$(grep -o "__DEMO_RESULT=${case_id}:\\(PASS\\|FAIL\\|SKIP\\)" "$evidence" | tail -1 | cut -d: -f2)"
  else
    status="FAIL"
  fi
  record "$case_id" "${status:-FAIL}" "$(basename "$evidence")"
}

run_vm_case T03 "$EU_VM" "$REMOTE_IP"
run_vm_case T04 "$EU_VM" ""
run_vm_case T05 "$EU_VM" ""
run_vm_case T06 "$EU_VM" ""
run_vm_case T07 "$EU_VM" ""

policy_evidence="$OUT/T08-T09-policy-and-exporter.json"
gateway_inspected=false
ssh_key="${CHECKPOINT_SSH_PRIVATE_KEY:-$HOME/.ssh/id_ed25519}"
if [[ -f "$ssh_key" ]] &&
  ssh -i "$ssh_key" \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=15 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$LOCAL_DIR/known_hosts" \
    "admin@$PUBLIC_IP" bash -s -- "$PACKAGE_NAME" \
    <"$ROOT/scripts/inspect-checkpoint.sh" \
    >"$policy_evidence" 2>&1; then
  gateway_inspected=true
elif az vm run-command invoke \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RG" \
    --name "$GATEWAY_VM" \
    --command-id RunShellScript \
    --scripts @"$ROOT/scripts/inspect-checkpoint.sh" \
    --parameters "$PACKAGE_NAME" \
    --only-show-errors \
    -o json >"$policy_evidence" 2>&1; then
  gateway_inspected=true
fi

if $gateway_inspected; then
  if grep -q 'CloudGuard Demo - Block Geo Outbound' "$policy_evidence" &&
    grep -q 'CloudGuard Demo - Block Geo Inbound' "$policy_evidence"; then
    record T08 PASS "$(basename "$policy_evidence")"
  else
    record T08 FAIL "$(basename "$policy_evidence")"
  fi
  if grep -q 'azure-monitor' "$policy_evidence"; then
    record T09 PASS "$(basename "$policy_evidence")"
  else
    record T09 FAIL "$(basename "$policy_evidence")"
  fi
else
  record T08 FAIL "$(basename "$policy_evidence")"
  record T09 FAIL "$(basename "$policy_evidence")"
fi

logs_evidence="$OUT/T10-log-analytics.json"
if az monitor log-analytics query \
  --subscription "$SUBSCRIPTION" \
  --workspace "$WORKSPACE" \
  --analytics-query "Syslog | where TimeGenerated > ago(2h) | where SyslogMessage has_any ('Check Point', 'action', 'product') | take 20" \
  -o json >"$logs_evidence" 2>&1 &&
  jq -e 'length > 0' "$logs_evidence" >/dev/null 2>&1; then
  record T10 PASS "$(basename "$logs_evidence")"
else
  record T10 PENDING_INGESTION "$(basename "$logs_evidence")"
fi

worm_evidence="$OUT/T11-worm-policy.json"
if az storage container immutability-policy show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RG" \
  --account-name "$ACCOUNT" \
  --container-name "$CONTAINER" \
  -o json >"$worm_evidence" 2>&1 &&
  jq -e --argjson retention "$RETENTION" '
    (.immutabilityPeriodSinceCreationInDays // .immutabilityPeriodInDays) == $retention
  ' "$worm_evidence" >/dev/null; then
  record T11 PASS "$(basename "$worm_evidence")"
else
  record T11 FAIL "$(basename "$worm_evidence")"
fi

region_evidence="$OUT/T12-eu-resource-locations.json"
az resource list \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RG" \
  --query '[].{name:name,type:type,location:location}' \
  -o json >"$region_evidence"
if python3 - "$region_evidence" <<'PY'
import json
import sys

allowed = {"westeurope", "northeurope", "francecentral", "germanywestcentral", "swedencentral", "global"}
resources = json.load(open(sys.argv[1], encoding="utf-8"))
invalid = [
    resource
    for resource in resources
    if resource.get("location") and resource["location"].lower() not in allowed
]
raise SystemExit(0 if resources and not invalid else 1)
PY
then
  record T12 PASS "$(basename "$region_evidence")"
else
  record T12 FAIL "$(basename "$region_evidence")"
fi

inbound_evidence="$OUT/T13-inbound.txt"
if [[ "$INBOUND_ENABLED" != "true" ]]; then
  printf 'Optional inbound demo is disabled.\n' >"$inbound_evidence"
  record T13 SKIP "$(basename "$inbound_evidence")"
elif curl -fsS --connect-timeout 10 --max-time 30 "http://${PUBLIC_IP}:18080/" >"$inbound_evidence" 2>&1; then
  record T13 PASS "$(basename "$inbound_evidence")"
else
  record T13 FAIL "$(basename "$inbound_evidence")"
fi

printf '%s\n' "${RESULTS[@]}" >"$OUT/results.tsv"
python3 - "$OUT/results.tsv" "$OUT/summary.json" <<'PY'
import datetime
import json
import sys

rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    case_id, status, evidence = line.rstrip("\n").split("|", 2)
    rows.append({"id": case_id, "status": status, "evidence": evidence})
with open(sys.argv[2], "w", encoding="utf-8") as output:
    json.dump(
        {
            "generatedUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "results": rows,
            "note": "PENDING_INGESTION and SKIP are deliberately not reported as PASS.",
        },
        output,
        indent=2,
    )
PY

echo "Evidence written to $OUT/summary.json."
