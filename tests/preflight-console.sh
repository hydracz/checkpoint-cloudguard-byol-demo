#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

load_runtime_environment

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/checkpoint-preflight-console.XXXXXX")"
trap 'rm -f "$temporary_dir/legacy.tfstate" "$temporary_dir/console.stderr"; rmdir "$temporary_dir"' EXIT
cp "$ROOT/tests/fixtures/legacy-two-subnets-state.json" "$temporary_dir/legacy.tfstate"

# Console uses only disposable local state, never the selected deployment workspace.
export TF_WORKSPACE=default
export TF_INPUT=0
export TF_CLI_ARGS=""
export TF_VAR_subscription_id="00000000-0000-0000-0000-000000000000"
export TF_VAR_admin_ssh_public_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
export TF_VAR_sic_key="validation-only-sic-key"
export TF_VAR_checkpoint_os_version="R82"
export TF_VAR_checkpoint_image_id=""
export TF_VAR_checkpoint_image_requires_plan=true

assert_console_value() {
  local expression="$1" expected="$2" actual

  if ! actual="$(terraform_console_value "$expression" 2>"$temporary_dir/console.stderr")"; then
    cat "$temporary_dir/console.stderr" >&2
    die "Terraform console failed for $expression."
  fi
  # Console can return a value and exit zero while reporting invalid outputs.
  if [[ -s "$temporary_dir/console.stderr" ]]; then
    cat "$temporary_dir/console.stderr" >&2
    die "Terraform console emitted diagnostics for $expression."
  fi
  [[ "$actual" == "$expected" ]] ||
    die "Expected $expression to return '$expected', got '$actual'."
}

for state in empty legacy; do
  export TF_CLI_ARGS_console="-no-color -state=\"$temporary_dir/$state.tfstate\""
  assert_console_value local.checkpoint_offer "check-point-cg-r82"
  assert_console_value module.checkpoint.management_subnet_id "(known after apply)"
done

cmp "$ROOT/tests/fixtures/legacy-two-subnets-state.json" "$temporary_dir/legacy.tfstate"
echo "Preflight console checks passed with empty and legacy two-subnet state."
