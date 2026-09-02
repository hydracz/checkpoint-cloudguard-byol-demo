#!/usr/bin/env bash
set -euo pipefail

CASE_ID="${1:?case ID is required}"
PEER_IP="${2:-}"
TLS_ENABLED="${3:-false}"
EXPECTED_CA_ISSUER="${4:-example.org}"
if [[ "$EXPECTED_CA_ISSUER" == base64:* ]]; then
  EXPECTED_CA_ISSUER="$(
    printf '%s' "${EXPECTED_CA_ISSUER#base64:}" |
      base64 -d
  )"
fi

result() {
  printf '__DEMO_RESULT=%s:%s\n' "$CASE_ID" "$1"
}

print_context() {
  printf 'EXECUTED_ON=%s\n' "$(hostname)"
  printf 'COMMAND=%s\n' "$1"
}

print_file_excerpt() {
  local file="$1"
  if [[ -s "$file" ]]; then
    printf '%s\n' '--- command output (first 4096 bytes) ---'
    head -c 4096 "$file"
    printf '\n%s\n' '--- end command output ---'
  else
    printf '%s\n' 'COMMAND_OUTPUT=<empty>'
  fi
}

case "$CASE_ID" in
  T03)
    url="http://${PEER_IP}:8080/"
    output_file=/tmp/checkpoint-demo-east-west.out
    print_context "curl -fsS --connect-timeout 10 --max-time 20 $url"
    if curl -fsS --connect-timeout 10 --max-time 20 "$url" >"$output_file" 2>&1; then
      print_file_excerpt "$output_file"
    else
      curl_status=$?
      print_file_excerpt "$output_file"
      printf 'CURL_EXIT_CODE=%s\n' "$curl_status"
      result FAIL
      exit 0
    fi
    if grep -q 'Check Point CloudGuard BYOL' "$output_file"; then
      result PASS
    else
      result FAIL
    fi
    ;;
  T04)
    url="https://httpbin.org/anything/allowed"
    output_file=/tmp/checkpoint-demo-allowed.json
    print_context "curl -fsS --connect-timeout 10 --max-time 30 -w 'HTTP_STATUS=%{http_code}' $url"
    if http_status="$(
      curl -fsS \
        --connect-timeout 10 \
        --max-time 30 \
        -o "$output_file" \
        -w '%{http_code}' \
        "$url"
    )"; then
      printf 'HTTP_STATUS=%s\n' "$http_status"
      print_file_excerpt "$output_file"
      result PASS
    else
      curl_status=$?
      printf 'HTTP_STATUS=%s\n' "${http_status:-000}"
      printf 'CURL_EXIT_CODE=%s\n' "$curl_status"
      print_file_excerpt "$output_file"
      result FAIL
    fi
    ;;
  T05)
    url="https://example.com/"
    output_file=/tmp/checkpoint-demo-domain-block.out
    print_context "curl -sS --connect-timeout 10 --max-time 20 -w 'HTTP_STATUS=%{http_code}' $url"
    set +e
    http_status="$(
      curl -sS \
        --connect-timeout 10 \
        --max-time 20 \
        -o "$output_file" \
        -w '%{http_code}' \
        "$url"
    )"
    curl_status=$?
    set -e
    printf 'HTTP_STATUS=%s\n' "${http_status:-000}"
    printf 'CURL_EXIT_CODE=%s\n' "$curl_status"
    print_file_excerpt "$output_file"
    if ((curl_status != 0)); then
      result PASS
    elif grep -q 'Example Domain' "$output_file"; then
      result FAIL
    else
      result PASS
    fi
    ;;
  T06)
    scheme="https"
    [[ "$TLS_ENABLED" == "true" ]] || scheme="http"
    allowed_url="${scheme}://httpbin.org/anything/allowed"
    blocked_url="${scheme}://httpbin.org/anything/blocked"
    rm -f /tmp/checkpoint-demo-url-allow.out /tmp/checkpoint-demo-url-block.out
    print_context "curl -sS --connect-timeout 10 --max-time 30 $allowed_url"
    allowed_code="$(curl -sS -o /tmp/checkpoint-demo-url-allow.out -w '%{http_code}' --connect-timeout 10 --max-time 30 "$allowed_url" || true)"
    printf 'ALLOWED_HTTP_STATUS=%s\n' "$allowed_code"
    print_file_excerpt /tmp/checkpoint-demo-url-allow.out
    printf 'COMMAND=%s\n' "curl -sS --connect-timeout 10 --max-time 30 $blocked_url"
    blocked_code="$(curl -sS -o /tmp/checkpoint-demo-url-block.out -w '%{http_code}' --connect-timeout 10 --max-time 30 "$blocked_url" || true)"
    printf 'BLOCKED_HTTP_STATUS=%s\n' "$blocked_code"
    print_file_excerpt /tmp/checkpoint-demo-url-block.out
    if [[ "$allowed_code" == "200" ]] &&
      grep -Fq "\"url\": \"$allowed_url\"" /tmp/checkpoint-demo-url-allow.out &&
      ! grep -Fq "\"url\": \"$blocked_url\"" /tmp/checkpoint-demo-url-block.out 2>/dev/null; then
      result PASS
    else
      printf 'allowed=%s blocked=%s\n' "$allowed_code" "$blocked_code"
      result FAIL
    fi
    ;;
  T07)
    if [[ "$TLS_ENABLED" != "true" ]]; then
      print_context "openssl s_client -connect www.microsoft.com:443 -servername www.microsoft.com"
      printf '%s\n' 'TLS inspection is disabled for this deployment.'
      result SKIP
      exit 0
    fi
    print_context "openssl s_client -connect www.microsoft.com:443 -servername www.microsoft.com | openssl x509 -noout -issuer -nameopt RFC2253"
    issuer="$(
      timeout 30 openssl s_client \
        -connect www.microsoft.com:443 \
        -servername www.microsoft.com \
        </dev/null 2>/dev/null |
        openssl x509 -noout -issuer -nameopt RFC2253 2>/dev/null || true
    )"
    printf '%s\n' "$issuer"
    if grep -Fqi "$EXPECTED_CA_ISSUER" <<<"$issuer"; then
      result PASS
    else
      result FAIL
    fi
    ;;
  *)
    echo "Unknown case: $CASE_ID" >&2
    exit 2
    ;;
esac
