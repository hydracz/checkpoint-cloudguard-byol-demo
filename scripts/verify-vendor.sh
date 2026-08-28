#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="infra/vendor/vendor-checksums.sha256"

if command -v shasum >/dev/null 2>&1; then
  (cd "$ROOT" && shasum -a 256 -c "$MANIFEST")
elif command -v sha256sum >/dev/null 2>&1; then
  (cd "$ROOT" && sha256sum -c "$MANIFEST")
else
  echo "Neither shasum nor sha256sum is available." >&2
  exit 1
fi

echo "Vendored Terraform module checksums passed."
