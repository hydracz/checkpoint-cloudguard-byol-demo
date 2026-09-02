#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

OUTPUTS_FILE=""
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --outputs-file)
      [[ $# -ge 2 ]] || die "--outputs-file requires a path."
      [[ -f "$2" ]] || die "Terraform outputs file not found: $2"
      OUTPUTS_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a path."
      OUT="$2"
      shift 2
      ;;
    *)
      die "Usage: $0 [--outputs-file FILE] [--output-dir DIR]"
      ;;
  esac
done

require_cmd az
require_cmd openssl
require_cmd python3

trace_outputs=false
if [[ "$-" == *x* ]]; then
  trace_outputs=true
  set +x
fi
outputs="$(load_terraform_outputs "$OUTPUTS_FILE")"
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
GATEWAY_NSG_ID="$(printf '%s' "$outputs" | jq -r '.checkpoint_nsg_id.value // ""')"
PACKAGE_NAME="$(output_value policy_package_name)"
CHECKPOINT_RELEASE="$(output_value checkpoint_os_version)"
R81_TLS_MANUAL="$(printf '%s' "$outputs" | jq -r '.r81_tls_manually_configured.value // false')"
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
MANAGEMENT_CIDRS_JSON="$(printf '%s' "$outputs" | jq -e -c '.management_cidrs.value')"
IMAGE_ID="$(printf '%s' "$outputs" | jq -r '.checkpoint_image_id.value // ""')"
IMAGE_REQUIRES_PLAN="$(output_value checkpoint_image_requires_plan)"
IMAGE_OFFER="$(output_value checkpoint_offer)"
IMAGE_PLAN="$(output_value checkpoint_plan)"
LOG_INGEST_WAIT_SECONDS="${LOG_INGEST_WAIT_SECONDS:-1800}"
LOG_INGEST_RETRY_SECONDS="${LOG_INGEST_RETRY_SECONDS:-60}"
RECONCILE_SSH_RULE="${CHECKPOINT_RECONCILE_SSH_RULE:-false}"
EXPECTED_CA_ISSUER="$COMPANY_DOMAIN"
[[ "$LOG_INGEST_WAIT_SECONDS" =~ ^[0-9]+$ ]] ||
  die "LOG_INGEST_WAIT_SECONDS must be a non-negative integer."
[[ "$LOG_INGEST_RETRY_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  die "LOG_INGEST_RETRY_SECONDS must be a positive integer."
[[ "$RECONCILE_SSH_RULE" == "true" || "$RECONCILE_SSH_RULE" == "false" ]] ||
  die "CHECKPOINT_RECONCILE_SSH_RULE must be true or false."
if [[ "$TLS_ENABLED" == "true" &&
  "$CHECKPOINT_RELEASE" == "R81" &&
  "$R81_TLS_MANUAL" == "true" ]]; then
  ca_file="${CHECKPOINT_TLS_CA_FILE:-}"
  [[ -f "$ca_file" ]] ||
    die "R81 manual TLS validation requires CHECKPOINT_TLS_CA_FILE with the deployment's public CA."
  if openssl x509 -in "$ca_file" -noout >/dev/null 2>&1; then
    ca_format=()
  elif openssl x509 -inform DER -in "$ca_file" -noout >/dev/null 2>&1; then
    ca_format=(-inform DER)
  else
    die "CHECKPOINT_TLS_CA_FILE must contain a PEM or DER X.509 public certificate."
  fi
  EXPECTED_CA_ISSUER="$(
    openssl x509 \
      "${ca_format[@]}" \
      -in "$ca_file" \
      -noout \
      -subject \
      -nameopt RFC2253 |
      sed 's/^subject=//'
  )"
fi
EXPECTED_CA_ISSUER_ARG="base64:$(printf '%s' "$EXPECTED_CA_ISSUER" | openssl base64 -A)"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$OUT" ]]; then
  OUT="$ROOT/evidence/$STAMP"
elif [[ "$OUT" != /* ]]; then
  OUT="$PWD/$OUT"
fi
[[ ! -e "$OUT/results.tsv" && ! -e "$OUT/report.html" ]] ||
  die "Output directory already contains validation results: $OUT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

printf '%s' "$outputs" |
  jq '
    with_entries(
      if (.value.sensitive // false)
      then .value.value = "<redacted>"
      else .
      end
    )
  ' >"$OUT/deployment-outputs.json"

if [[ -n "$OUTPUTS_FILE" ]]; then
  outputs_source="outputs-file:${OUTPUTS_FILE##*/}"
else
  outputs_source="terraform-state"
fi
jq -n \
  --arg generatedUtc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg outputsSource "$outputs_source" \
  '{generatedUtc: $generatedUtc, outputsSource: $outputsSource}' \
  >"$OUT/validation-metadata.json"
unset outputs
unset -f output_value
if $trace_outputs; then
  set -x
fi

RESULTS=()
record() {
  RESULTS+=("$1|$2|$3")
}

ssh_key="${CHECKPOINT_SSH_PRIVATE_KEY:-$DEFAULT_SSH_PRIVATE_KEY}"
if [[ "$RECONCILE_SSH_RULE" == "true" ]]; then
  trap remove_temporary_restricted_ssh_nsg_rule EXIT
  ensure_restricted_ssh_nsg_rules "$SUBSCRIPTION" "$RG" "$GATEWAY_NSG_ID" "$MANAGEMENT_CIDRS_JSON"
fi
metadata_tmp="$OUT/validation-metadata.json.tmp"
jq \
  --argjson temporarySshRuleCreated "$RESTRICTED_SSH_RULE_CREATED" \
  '.temporarySshRuleCreated = $temporarySshRuleCreated' \
  "$OUT/validation-metadata.json" >"$metadata_tmp"
mv "$metadata_tmp" "$OUT/validation-metadata.json"

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

image_evidence="$OUT/T14-image-and-plan.json"
if az vm show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RG" \
  --name "$GATEWAY_VM" \
  --query '{name:name,location:location,vmSize:hardwareProfile.vmSize,imageReference:storageProfile.imageReference,plan:plan,provisioningState:provisioningState}' \
  -o json >"$image_evidence" 2>&1 &&
  jq -e \
    --arg image_id "$IMAGE_ID" \
    --arg offer "$IMAGE_OFFER" \
    --arg plan "$IMAGE_PLAN" \
    --argjson requires_plan "$IMAGE_REQUIRES_PLAN" '
      (if $image_id != "" then
         ((.imageReference.id // "") | ascii_downcase) ==
         ($image_id | ascii_downcase)
       else
         (.imageReference.publisher | ascii_downcase) == "checkpoint" and
         .imageReference.offer == $offer and
         .imageReference.sku == $plan
       end) and
      (if $requires_plan then
         (.plan.publisher | ascii_downcase) == "checkpoint" and
         .plan.product == $offer and
         .plan.name == $plan
       else
         .plan == null
       end)
    ' "$image_evidence" >/dev/null; then
  record T14 PASS "$(basename "$image_evidence")"
else
  record T14 FAIL "$(basename "$image_evidence")"
fi

management_nsg_evidence="$OUT/T17-management-nsg-rules.json"
management_nsg_name="${GATEWAY_NSG_ID##*/}"
if az network nsg rule list \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RG" \
  --nsg-name "$management_nsg_name" \
  -o json >"$management_nsg_evidence" 2>&1 &&
  jq -e \
    --argjson cidrs "$MANAGEMENT_CIDRS_JSON" '
      def sources:
        if ((.sourceAddressPrefixes // []) | length) > 0 then
          .sourceAddressPrefixes
        elif (.sourceAddressPrefix // "") != "" then
          [.sourceAddressPrefix]
        else
          []
        end;
      {
        AllowRestrictedSSH: "22",
        AllowRestrictedGaiaPortal: "443",
        AllowRestrictedSmartConsole18190: "18190",
        AllowRestrictedSmartConsole19009: "19009"
      } as $expected |
      [.[] | select($expected[.name] != null)] as $rules |
      ($rules | length) == 4 and
      all($rules[];
        .direction == "Inbound" and
        .access == "Allow" and
        (.protocol | ascii_downcase) == "tcp" and
        .destinationPortRange == $expected[.name] and
        (sources | sort) == ($cidrs | sort)
      )
    ' "$management_nsg_evidence" >/dev/null; then
  if [[ "$RESTRICTED_SSH_RULE_CREATED" == "true" ]]; then
    record T17 RECONCILED "$(basename "$management_nsg_evidence")"
  else
    record T17 PASS "$(basename "$management_nsg_evidence")"
  fi
else
  record T17 FAIL "$(basename "$management_nsg_evidence")"
fi

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
    --parameters \
    "arg1=$case_id" \
    "arg2=$peer_ip" \
    "arg3=$TLS_ENABLED" \
    "arg4=$EXPECTED_CA_ISSUER_ARG" \
    --only-show-errors \
    -o json >"$evidence" 2>&1; then
    status="$(
     grep -o "__DEMO_RESULT=${case_id}:\\(PASS\\|FAIL\\|SKIP\\)" "$evidence" |
       tail -1 |
       cut -d: -f2 ||
       true
    )"
  else
    status="FAIL"
  fi
  record "$case_id" "${status:-FAIL}" "$(basename "$evidence")"
}

run_vm_case T03 "$EU_VM" "$REMOTE_IP"

east_west_source_evidence="$OUT/T16-east-west-source.json"
if az vm run-command invoke \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RG" \
  --name "$REMOTE_VM" \
  --command-id RunShellScript \
  --scripts "journalctl -u demo-web.service --since '10 minutes ago' --no-pager | grep -F '$EU_IP'" \
  --only-show-errors \
  -o json >"$east_west_source_evidence" 2>&1; then
  record T16 PASS "$(basename "$east_west_source_evidence")"
else
  record T16 FAIL "$(basename "$east_west_source_evidence")"
fi

run_vm_case T04 "$EU_VM" ""
run_vm_case T05 "$EU_VM" ""
run_vm_case T06 "$EU_VM" ""
run_vm_case T07 "$EU_VM" ""

policy_evidence="$OUT/T08-T09-policy-and-exporter.json"
gateway_inspected=false
if [[ -f "$ssh_key" ]] &&
  ssh -i "$ssh_key" \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=15 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$LOCAL_DIR/known_hosts" \
    "admin@$PUBLIC_IP" bash -s -- "$PACKAGE_NAME" "$CHECKPOINT_RELEASE" \
    <"$ROOT/scripts/inspect-checkpoint.sh" \
    >"$policy_evidence" 2>&1; then
  gateway_inspected=true
elif az vm run-command invoke \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RG" \
    --name "$GATEWAY_VM" \
    --command-id RunShellScript \
    --scripts @"$ROOT/scripts/inspect-checkpoint.sh" \
    --parameters "arg1=$PACKAGE_NAME" "arg2=$CHECKPOINT_RELEASE" \
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
  case "$CHECKPOINT_RELEASE" in
    R8210) expected_guest_release='R82.10' ;;
    *) expected_guest_release="$CHECKPOINT_RELEASE" ;;
  esac
  reported_guest_release="$(
    sed -n 's/^Product version Check Point Gaia \([^[:space:]]*\).*$/\1/p' "$policy_evidence" |
      tail -1
  )"
  if [[ "$reported_guest_release" == "$expected_guest_release" ]]; then
    record T15 PASS "$(basename "$policy_evidence")"
  else
    record T15 FAIL "$(basename "$policy_evidence")"
  fi
else
  record T08 FAIL "$(basename "$policy_evidence")"
  record T09 FAIL "$(basename "$policy_evidence")"
  record T15 FAIL "$(basename "$policy_evidence")"
fi

logs_evidence="$OUT/T10-log-analytics.json"
logs_ready=false
logs_deadline=$((SECONDS + LOG_INGEST_WAIT_SECONDS))
while true; do
  if az monitor log-analytics query \
    --subscription "$SUBSCRIPTION" \
    --workspace "$WORKSPACE" \
    --analytics-query "Syslog | where TimeGenerated > ago(2h) | where SyslogMessage contains 'action=\"Accept\"' or SyslogMessage contains 'action=\"Drop\"' or SyslogMessage contains 'rule_action=\"Accept\"' or SyslogMessage contains 'rule_action=\"Drop\"' | project TimeGenerated, Computer, HostName, SeverityLevel, SyslogMessage | order by TimeGenerated desc | take 50" \
    -o json >"$logs_evidence" 2>&1 &&
    jq -e '
      if type == "array" then length > 0
      elif (.tables? | type) == "array" then (.tables[0].rows | length) > 0
      else false
      end
    ' "$logs_evidence" >/dev/null 2>&1; then
    logs_ready=true
    break
  fi
  ((SECONDS >= logs_deadline)) && break
  sleep "$LOG_INGEST_RETRY_SECONDS"
done
if $logs_ready; then
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
if az resource list \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RG" \
    --query '[].{name:name,type:type,location:location}' \
    -o json >"$region_evidence" 2>&1 &&
  python3 - "$region_evidence" <<'PY'
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

cleanup_exit_code=0
remove_temporary_restricted_ssh_nsg_rule || cleanup_exit_code=1
trap - EXIT

if ((cleanup_exit_code != 0)); then
  for result_index in "${!RESULTS[@]}"; do
    if [[ "${RESULTS[$result_index]}" == T17\|RECONCILED\|* ]]; then
      RESULTS[$result_index]="T17|FAIL|$(basename "$management_nsg_evidence")"
    fi
  done
fi

printf '%s\n' "${RESULTS[@]}" >"$OUT/results.tsv"
validation_exit_code=0
if awk -F '|' '$2 != "PASS" && $2 != "SKIP" && $2 != "RECONCILED" { failed = 1 } END { exit(failed ? 0 : 1) }' "$OUT/results.tsv"; then
  validation_exit_code=1
fi
python3 "$ROOT/scripts/render-test-report.py" \
  --evidence-dir "$OUT" \
  --exit-code "$validation_exit_code"

echo "Evidence written to $OUT/report.html and $OUT/summary.json."
if ((validation_exit_code != 0)); then
  echo "One or more required tests did not pass. See $OUT/report.html." >&2
  exit "$validation_exit_code"
fi
