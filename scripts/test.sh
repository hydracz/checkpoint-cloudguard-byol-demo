#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="$ROOT/infra"
TERRAFORM="${TERRAFORM:-terraform}"

command -v "$TERRAFORM" >/dev/null 2>&1 || {
  echo "ERROR: Required command not found: $TERRAFORM" >&2
  exit 1
}

"$ROOT/scripts/verify-vendor.sh"
"$TERRAFORM" -chdir="$INFRA" fmt -recursive -check
"$TERRAFORM" -chdir="$INFRA" init -backend=false -input=false
"$TERRAFORM" -chdir="$INFRA" validate
"$TERRAFORM" -chdir="$INFRA" test
"$ROOT/tests/validate-repo.sh"

echo "Independent repository and Terraform tests passed."
