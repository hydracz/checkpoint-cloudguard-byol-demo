#!/usr/bin/env bash
set -euo pipefail

CASE_ID="${1:?case ID is required}"
PEER_IP="${2:-}"
TLS_ENABLED="${3:-false}"
EXPECTED_CA_ISSUER="${4:-example.org}"

result() {
  printf '__DEMO_RESULT=%s:%s\n' "$CASE_ID" "$1"
}

case "$CASE_ID" in
  T03)
    if curl -fsS --connect-timeout 10 --max-time 20 "http://${PEER_IP}:8080/" | grep -q 'Check Point CloudGuard BYOL'; then
      result PASS
    else
      result FAIL
    fi
    ;;
  T04)
    if curl -fsS --connect-timeout 10 --max-time 30 "https://httpbin.org/anything/allowed" >/tmp/checkpoint-demo-allowed.json; then
      result PASS
    else
      result FAIL
    fi
    ;;
  T05)
    if ! curl -sS --connect-timeout 10 --max-time 20 "https://example.com/" >/tmp/checkpoint-demo-domain-block.out 2>&1; then
      result PASS
    elif grep -q 'Example Domain' /tmp/checkpoint-demo-domain-block.out; then
      result FAIL
    else
      result PASS
    fi
    ;;
  T06)
    allowed_code="$(curl -sS -o /tmp/checkpoint-demo-url-allow.out -w '%{http_code}' --connect-timeout 10 --max-time 30 "https://httpbin.org/anything/allowed" || true)"
    blocked_code="$(curl -sS -o /tmp/checkpoint-demo-url-block.out -w '%{http_code}' --connect-timeout 10 --max-time 30 "https://httpbin.org/anything/blocked" || true)"
    if [[ "$allowed_code" == "200" ]] &&
      grep -q '"url": "https://httpbin.org/anything/allowed"' /tmp/checkpoint-demo-url-allow.out &&
      ! grep -q '"url": "https://httpbin.org/anything/blocked"' /tmp/checkpoint-demo-url-block.out; then
      result PASS
    else
      printf 'allowed=%s blocked=%s\n' "$allowed_code" "$blocked_code"
      result FAIL
    fi
    ;;
  T07)
    if [[ "$TLS_ENABLED" != "true" ]]; then
      result SKIP
      exit 0
    fi
    issuer="$(
      timeout 30 openssl s_client \
        -connect www.microsoft.com:443 \
        -servername www.microsoft.com \
        </dev/null 2>/dev/null |
        openssl x509 -noout -issuer 2>/dev/null || true
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
