#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 17 ]]; then
  echo "Expected 17 arguments; received $#." >&2
  exit 2
fi

GATEWAY_NAME="$1"
PACKAGE_NAME="$2"
FRONTEND_IP="$3"
BACKEND_IP="$4"
COLLECTOR_IP="$5"
EU_CIDR="$6"
REMOTE_CIDR="$7"
EU_HOST_IP="$8"
COUNTRIES_B64="$9"
APPLICATIONS_B64="${10}"
URLS_B64="${11}"
TLS_ENABLED="${12}"
INBOUND_ENABLED="${13}"
INBOUND_SOURCE_CIDR="${14}"
PUBLIC_IP="${15}"
MANAGEMENT_CIDR="${16}"
COMPANY_DOMAIN="${17}"

RULE_PREFIX="CloudGuard Demo - "
HTTPS_LAYER="CloudGuard Demo Outbound HTTPS"
EU_NETWORK="CloudGuard-EU-Spoke"
REMOTE_NETWORK="CloudGuard-Remote-Spoke"
MANAGEMENT_NETWORK="CloudGuard-Management-Source"
PROTECTED_GROUP="CloudGuard-Protected-Networks"
EU_WEB_HOST="CloudGuard-EU-Web"
BLOCKED_URLS_OBJECT="CloudGuard-Demo-Blocked-URLs"
INBOUND_SOURCE_OBJECT="CloudGuard-Inbound-Source"
INBOUND_SERVICE="CloudGuard-Demo-Inbound-18080"
CERTIFICATE_NAME="CloudGuardDemoOutboundCA"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required Check Point command not found: $1" >&2
    exit 1
  }
}

log() {
  printf '[checkpoint-policy] %s\n' "$*" >&2
}

decode_json() {
  printf '%s' "$1" | base64 -d
}

require_command mgmt_cli
require_command jq
require_command cp_log_export
require_command openssl
require_command base64
require_command clish
require_command timeout

COUNTRIES_JSON="$(decode_json "$COUNTRIES_B64")"
APPLICATIONS_JSON="$(decode_json "$APPLICATIONS_B64")"
URLS_JSON="$(decode_json "$URLS_B64")"

log "Waiting for the standalone Management API..."
ready=false
for attempt in $(seq 1 30); do
  if timeout 30 mgmt_cli -r true show packages limit 1 --format json >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 30
done
$ready || {
  echo "Management API did not become ready within 30 minutes." >&2
  exit 1
}

if ! timeout 60 mgmt_cli -r true show updatable-objects-repository-content \
  filter.text "China" limit 1 --format json >/dev/null 2>&1; then
  log "Initializing the Updatable Objects repository."
  timeout 300 mgmt_cli -r true update-updatable-objects-repository-content \
    --format json >/dev/null
fi

BACKEND_AZURE_GATEWAY="${BACKEND_IP%.*}.1"
COLLECTOR_CIDR="${COLLECTOR_IP%.*}.0/24"
for internal_cidr in "$EU_CIDR" "$REMOTE_CIDR" "$COLLECTOR_CIDR"; do
  clish -c "set static-route $internal_cidr nexthop gateway address $BACKEND_AZURE_GATEWAY on"
done
clish -c "save config"

SESSION_FILE="$(mktemp)"
PUBLISHED=false
cleanup() {
  if [[ -s "$SESSION_FILE" ]]; then
    sid="$(jq -r '.sid // empty' "$SESSION_FILE" 2>/dev/null || true)"
    if [[ -n "$sid" ]]; then
      if ! $PUBLISHED; then
        mgmt_cli discard --session-id "$sid" --format json >/dev/null 2>&1 || true
      fi
      mgmt_cli logout --session-id "$sid" --format json >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$SESSION_FILE"
}
trap cleanup EXIT

timeout 120 mgmt_cli -r true login --format json >"$SESSION_FILE"
SID="$(jq -e -r '.sid' "$SESSION_FILE")"

api() {
  local output status
  set +e
  output="$(timeout 180 mgmt_cli "$@" --session-id "$SID" --format json 2>&1)"
  status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    printf '%s\n' "$output" >&2
    return "$status"
  fi
  printf '%s\n' "$output"
}

PACKAGE_JSON="$(api show package name "$PACKAGE_NAME" details-level full)"
ACCESS_LAYER="$(printf '%s' "$PACKAGE_JSON" | jq -e -r '."access-layers"[0].name')"
api set access-layer \
  name "$ACCESS_LAYER" \
  applications-and-url-filtering true \
  >/dev/null

GATEWAYS_JSON="$(api show gateways-and-servers limit 100 details-level full)"
GATEWAY_OBJECT="$(
  printf '%s' "$GATEWAYS_JSON" |
    jq -e -c --arg name "$GATEWAY_NAME" --arg ip "$FRONTEND_IP" '
      [.objects[] | select(.name == $name or ."ipv4-address" == $ip)][0]
    '
)"
GATEWAY_UID="$(printf '%s' "$GATEWAY_OBJECT" | jq -e -r '.uid')"
MANAGED_GATEWAY_NAME="$(printf '%s' "$GATEWAY_OBJECT" | jq -e -r '.name')"

log "Configuring gateway blades and Azure interface topology."
api set simple-gateway \
  uid "$GATEWAY_UID" \
  firewall true \
  application-control true \
  url-filtering true \
  nat-hide-internal-interfaces true \
  interfaces.1.name eth0 \
  interfaces.1.ipv4-address "$FRONTEND_IP" \
  interfaces.1.ipv4-network-mask 255.255.255.0 \
  interfaces.1.anti-spoofing true \
  interfaces.1.topology external \
  interfaces.2.name eth1 \
  interfaces.2.ipv4-address "$BACKEND_IP" \
  interfaces.2.ipv4-network-mask 255.255.255.0 \
  interfaces.2.anti-spoofing true \
  interfaces.2.topology internal \
  interfaces.2.topology-settings.ip-address-behind-this-interface "network defined by routing" \
  >/dev/null

ACCESS_RULEBASE="$(api show access-rulebase name "$ACCESS_LAYER" limit 500 details-level standard)"
while IFS= read -r uid; do
  [[ -n "$uid" ]] && api delete access-rule layer "$ACCESS_LAYER" uid "$uid" >/dev/null
done < <(
  printf '%s' "$ACCESS_RULEBASE" |
    jq -r --arg prefix "$RULE_PREFIX" \
      '.. | objects | select(.type? == "access-rule" and (.name? | startswith($prefix))) | .uid'
)

NAT_RULEBASE="$(api show nat-rulebase package "$PACKAGE_NAME" limit 500 details-level standard)"
while IFS= read -r uid; do
  [[ -n "$uid" ]] && api delete nat-rule package "$PACKAGE_NAME" uid "$uid" >/dev/null
done < <(
  printf '%s' "$NAT_RULEBASE" |
    jq -r --arg prefix "$RULE_PREFIX" \
      '.. | objects | select(.type? == "nat-rule" and (.name? | startswith($prefix))) | .uid'
)

if api show https-layer name "$HTTPS_LAYER" >/dev/null 2>&1; then
  HTTPS_RULEBASE="$(api show https-rulebase name "$HTTPS_LAYER" limit 500 details-level standard)"
  while IFS= read -r uid; do
    [[ -n "$uid" ]] && api delete https-rule layer "$HTTPS_LAYER" uid "$uid" >/dev/null
  done < <(
    printf '%s' "$HTTPS_RULEBASE" |
      jq -r --arg prefix "$RULE_PREFIX" \
        '.. | objects | select(.type? == "https-rule" and (.name? | startswith($prefix))) | .uid'
  )
fi

ensure_network() {
  local name="$1" subnet="$2" mask_length="$3"
  if api show network name "$name" >/dev/null 2>&1; then
    api set network name "$name" subnet4 "$subnet" mask-length4 "$mask_length" >/dev/null
  else
    api add network name "$name" subnet4 "$subnet" mask-length4 "$mask_length" >/dev/null
  fi
}

ensure_host() {
  local name="$1" address="$2"
  if api show host name "$name" >/dev/null 2>&1; then
    api set host name "$name" ipv4-address "$address" >/dev/null
  else
    api add host name "$name" ipv4-address "$address" >/dev/null
  fi
}

ensure_service_tcp() {
  local name="$1" port="$2"
  if api show service-tcp name "$name" >/dev/null 2>&1; then
    api set service-tcp name "$name" port "$port" >/dev/null
  else
    api add service-tcp name "$name" port "$port" >/dev/null
  fi
}

ensure_network "$EU_NETWORK" "${EU_CIDR%/*}" "${EU_CIDR#*/}"
ensure_network "$REMOTE_NETWORK" "${REMOTE_CIDR%/*}" "${REMOTE_CIDR#*/}"
ensure_network "$MANAGEMENT_NETWORK" "${MANAGEMENT_CIDR%/*}" "${MANAGEMENT_CIDR#*/}"
ensure_host "$EU_WEB_HOST" "$EU_HOST_IP"
WEB_SERVICE="HTTP_proxy"

if api show group name "$PROTECTED_GROUP" >/dev/null 2>&1; then
  api delete group name "$PROTECTED_GROUP" >/dev/null
fi
api add group \
  name "$PROTECTED_GROUP" \
  members.1 "$EU_NETWORK" \
  members.2 "$REMOTE_NETWORK" \
  >/dev/null

if api show application-site name "$BLOCKED_URLS_OBJECT" >/dev/null 2>&1; then
  api delete application-site name "$BLOCKED_URLS_OBJECT" >/dev/null
fi
url_command=(
  add application-site
  name "$BLOCKED_URLS_OBJECT"
  primary-category "Custom_Application_Site"
  urls-defined-as-regular-expression false
)
url_index=1
while IFS= read -r url; do
  url_command+=("url-list.$url_index" "$url")
  url_index=$((url_index + 1))
done < <(printf '%s' "$URLS_JSON" | jq -e -r '.[]')
api "${url_command[@]}" >/dev/null

APPLICATION_OBJECTS=("$BLOCKED_URLS_OBJECT")
while IFS= read -r application; do
  if ! api show application-site name "$application" >/dev/null 2>&1; then
    api show application-site-category name "$application" >/dev/null
  fi
  APPLICATION_OBJECTS+=("$application")
done < <(printf '%s' "$APPLICATIONS_JSON" | jq -e -r '.[]')

GEO_OBJECTS=()
while IFS= read -r country; do
  repository_json="$(api show updatable-objects-repository-content filter.text "$country" limit 500 details-level full)"
  repository_object="$(
    printf '%s' "$repository_json" |
      jq -e -c --arg country "$country" '
        [.objects[] | select(."name-in-updatable-objects-repository" == $country)][0]
      '
  )"
  repository_uid="$(printf '%s' "$repository_object" | jq -e -r '."uid-in-updatable-objects-repository"')"
  imported_uid="$(printf '%s' "$repository_object" | jq -r '."updatable-object".uid // empty')"
  if [[ -z "$imported_uid" ]]; then
    imported_json="$(api add updatable-object \
      uid-in-updatable-objects-repository "$repository_uid")"
    imported_uid="$(printf '%s' "$imported_json" | jq -e -r '.uid')"
  fi
  GEO_OBJECTS+=("$imported_uid")
done < <(printf '%s' "$COUNTRIES_JSON" | jq -e -r '.[]')

add_access_rule() {
  api add access-rule "$@" >/dev/null
}

add_access_rule \
  layer "$ACCESS_LAYER" position 1 \
  name "${RULE_PREFIX}Cleanup Drop" \
  source.1 Any destination.1 Any service.1 Any \
  action Drop track.type Log install-on.1 "$MANAGED_GATEWAY_NAME"

add_access_rule \
  layer "$ACCESS_LAYER" position 1 \
  name "${RULE_PREFIX}Allow Web and DNS Egress" \
  source.1 "$PROTECTED_GROUP" destination.1 Any \
  service.1 http service.2 https service.3 domain-udp service.4 domain-tcp \
  action Accept track.type "Extended Log" install-on.1 "$MANAGED_GATEWAY_NAME"

add_access_rule \
  layer "$ACCESS_LAYER" position 1 \
  name "${RULE_PREFIX}Allow Inspected East West Web" \
  source.1 "$PROTECTED_GROUP" destination.1 "$PROTECTED_GROUP" \
  service.1 "$WEB_SERVICE" \
  action Accept track.type "Extended Log" install-on.1 "$MANAGED_GATEWAY_NAME"

if [[ "$INBOUND_ENABLED" == "true" ]]; then
  ensure_network "$INBOUND_SOURCE_OBJECT" "${INBOUND_SOURCE_CIDR%/*}" "${INBOUND_SOURCE_CIDR#*/}"
  ensure_service_tcp "$INBOUND_SERVICE" "18080"
  add_access_rule \
    layer "$ACCESS_LAYER" position 1 \
    name "${RULE_PREFIX}Restricted North South Inbound" \
    source.1 "$INBOUND_SOURCE_OBJECT" destination.1 "$MANAGED_GATEWAY_NAME" \
    service.1 "$INBOUND_SERVICE" \
    action Accept track.type "Extended Log" install-on.1 "$MANAGED_GATEWAY_NAME"

  api add nat-rule \
    package "$PACKAGE_NAME" position 1 \
    name "${RULE_PREFIX}DNAT 18080 to EU Web" \
    original-source Any \
    original-destination "$MANAGED_GATEWAY_NAME" \
    original-service "$INBOUND_SERVICE" \
    translated-source Original \
    translated-destination "$EU_WEB_HOST" \
    translated-service "$WEB_SERVICE" \
    method static \
    install-on "$MANAGED_GATEWAY_NAME" \
    >/dev/null
fi

application_rule=(add access-rule
  layer "$ACCESS_LAYER" position 1
  name "${RULE_PREFIX}Block Domains URLs and Applications"
  source.1 "$PROTECTED_GROUP"
  destination.1 Any
  action Drop
  track.type "Extended Log"
  install-on.1 "$MANAGED_GATEWAY_NAME")
application_index=1
for application in "${APPLICATION_OBJECTS[@]}"; do
  application_rule+=("service.$application_index" "$application")
  application_index=$((application_index + 1))
done
api "${application_rule[@]}" >/dev/null

geo_outbound=(add access-rule
  layer "$ACCESS_LAYER" position 1
  name "${RULE_PREFIX}Block Geo Outbound"
  source.1 "$PROTECTED_GROUP"
  service.1 Any
  action Drop
  track.type "Extended Log"
  install-on.1 "$MANAGED_GATEWAY_NAME")
geo_inbound=(add access-rule
  layer "$ACCESS_LAYER" position 1
  name "${RULE_PREFIX}Block Geo Inbound"
  destination.1 Any
  service.1 Any
  action Drop
  track.type "Extended Log"
  install-on.1 "$MANAGED_GATEWAY_NAME")
geo_index=1
for geo_object in "${GEO_OBJECTS[@]}"; do
  geo_outbound+=("destination.$geo_index" "$geo_object")
  geo_inbound+=("source.$geo_index" "$geo_object")
  geo_index=$((geo_index + 1))
done
api "${geo_outbound[@]}" >/dev/null
api "${geo_inbound[@]}" >/dev/null

add_access_rule \
  layer "$ACCESS_LAYER" position 1 \
  name "${RULE_PREFIX}Allow Restricted Management SSH" \
  source.1 "$MANAGEMENT_NETWORK" destination.1 "$MANAGED_GATEWAY_NAME" \
  service.1 ssh \
  action Accept track.type Log install-on.1 "$MANAGED_GATEWAY_NAME"

add_access_rule \
  layer "$ACCESS_LAYER" position 1 \
  name "${RULE_PREFIX}Allow Gateway Services" \
  source.1 "$MANAGED_GATEWAY_NAME" destination.1 Any \
  service.1 http service.2 https service.3 domain-udp service.4 domain-tcp service.5 syslog \
  action Accept track.type Log install-on.1 "$MANAGED_GATEWAY_NAME"

CA_PUBLIC_B64=""
if [[ "$TLS_ENABLED" == "true" ]]; then
  if certificate_json="$(api show outbound-inspection-certificate name "$CERTIFICATE_NAME" details-level full 2>/dev/null)"; then
    :
  else
    valid_from="$(date -u +%Y-%m-%d)"
    valid_to="$(date -u -d '+365 days' +%Y-%m-%d)"
    certificate_password_b64="$(
      openssl rand -hex 6 |
        tr -d '\n' |
        base64 |
        tr -d '\n'
    )"
    certificate_json="$(api add outbound-inspection-certificate \
      name "$CERTIFICATE_NAME" \
      issued-by "$COMPANY_DOMAIN" \
      base64-password "$certificate_password_b64" \
      valid-from "$valid_from" \
      valid-to "$valid_to" \
      is-default true)"
  fi
  CA_PUBLIC_B64="$(
    printf '%s' "$certificate_json" |
      jq -e -r '."base64-public-certificate"' |
      base64 |
      tr -d '\n'
  )"
  api set simple-gateway uid "$GATEWAY_UID" enable-https-inspection true >/dev/null

  if ! api show https-layer name "$HTTPS_LAYER" >/dev/null 2>&1; then
    api add https-layer name "$HTTPS_LAYER" layer-type outbound >/dev/null
  fi
  api set package \
    name "$PACKAGE_NAME" \
    https-inspection-layers.outbound-https-layer "$HTTPS_LAYER" \
    >/dev/null

  api add https-rule \
    layer "$HTTPS_LAYER" position 1 \
    name "${RULE_PREFIX}Inspect Protected Egress" \
    source.1 "$PROTECTED_GROUP" \
    destination.1 Internet \
    service.1 "HTTPS default services" \
    site-category.1 Any \
    blade.1 "Application Control" \
    blade.2 "Url Filtering" \
    action Inspect \
    track Log \
    install-on.1 "$MANAGED_GATEWAY_NAME" \
    >/dev/null
else
  api set simple-gateway uid "$GATEWAY_UID" enable-https-inspection false >/dev/null
fi

api publish >/dev/null
PUBLISHED=true
mgmt_cli logout --session-id "$SID" --format json >/dev/null
rm -f "$SESSION_FILE"
trap - EXIT

log "Installing access and HTTPS inspection policy."
set +e
install_output="$(
  timeout 900 mgmt_cli -r true install-policy \
    policy-package "$PACKAGE_NAME" \
    targets "$MANAGED_GATEWAY_NAME" \
    access true \
    threat-prevention false \
    --format json 2>&1
)"
install_status=$?
set -e
if [[ $install_status -ne 0 ]]; then
  printf '%s\n' "$install_output" >&2
  exit "$install_status"
fi

if cp_log_export show name azure-monitor >/dev/null 2>&1; then
  cp_log_export set \
    name azure-monitor \
    target-server "$COLLECTOR_IP" \
    target-port 514 \
    protocol udp \
    format generic \
    read-mode semi-unified \
    --apply-now \
    >/dev/null
else
  cp_log_export add \
    name azure-monitor \
    target-server "$COLLECTOR_IP" \
    target-port 514 \
    protocol udp \
    format generic \
    read-mode semi-unified \
    --apply-now \
    >/dev/null
fi

log "Configured policy for public IP $PUBLIC_IP and Log Exporter target $COLLECTOR_IP."
if [[ -n "$CA_PUBLIC_B64" ]]; then
  printf 'DEMO_TLS_CA_B64=%s\n' "$CA_PUBLIC_B64"
fi
printf 'DEMO_POLICY_STATUS=complete\n'
