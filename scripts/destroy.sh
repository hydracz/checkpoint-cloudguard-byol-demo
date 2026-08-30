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
      die "Usage: CONFIRM_DESTROY=<resource-group> $0 [--var-file FILE]"
      ;;
  esac
done

load_deployment_environment "$VAR_FILE"
RG="$(terraform_output_raw resource_group_name)"
[[ "${CONFIRM_DESTROY:-}" == "$RG" ]] ||
  die "Set CONFIRM_DESTROY=$RG to confirm destruction."

if [[ -n "$VAR_FILE" ]]; then
  "$TERRAFORM" -chdir="$INFRA" destroy \
    -input=false \
    -auto-approve \
    -parallelism="$TF_PARALLELISM" \
    "-var-file=$VAR_FILE"
else
  "$TERRAFORM" -chdir="$INFRA" destroy \
    -input=false \
    -auto-approve \
    -parallelism="$TF_PARALLELISM"
fi
rm -f "$INFRA/audit.auto.tfvars.json" "$LOCAL_DIR/plan.tfplan"
echo "Terraform destroy completed for $RG. Log Analytics is permanently deleted; a locked WORM policy can intentionally prevent storage deletion until retention expires."
