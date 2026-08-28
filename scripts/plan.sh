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
"$TERRAFORM" -chdir="$INFRA" init -backend=false -input=false

args=()
if [[ -n "$VAR_FILE" ]]; then
  args+=("-var-file=$VAR_FILE")
fi

"$TERRAFORM" -chdir="$INFRA" plan \
  -input=false \
  -parallelism="$TF_PARALLELISM" \
  -out="$LOCAL_DIR/plan.tfplan" \
  "${args[@]}"

echo "Saved reviewed plan to $LOCAL_DIR/plan.tfplan."
