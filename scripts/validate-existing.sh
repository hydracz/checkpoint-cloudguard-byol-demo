#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

OUTPUTS_FILE=""
OUTPUT_DIR=""
EXPECTED_RELEASE=""
CONFIGURE_POLICY=false
CA_FILE="${CHECKPOINT_TLS_CA_FILE:-}"

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
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --expected-release)
      [[ $# -ge 2 ]] || die "--expected-release requires R81, R82, or R8210."
      EXPECTED_RELEASE="$2"
      shift 2
      ;;
    --configure-policy)
      CONFIGURE_POLICY=true
      shift
      ;;
    --ca-file)
      [[ $# -ge 2 ]] || die "--ca-file requires a path."
      [[ -f "$2" ]] || die "Public CA file not found: $2"
      CA_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
      shift 2
      ;;
    *)
      die "Usage: $0 [--outputs-file FILE] [--output-dir DIR] [--expected-release R81|R82|R8210] [--configure-policy] [--ca-file FILE]"
      ;;
  esac
done

if [[ -z "$OUTPUTS_FILE" && -f "$LOCAL_DIR/latest-deployment-outputs.json" ]]; then
  OUTPUTS_FILE="$LOCAL_DIR/latest-deployment-outputs.json"
fi
if [[ -n "$EXPECTED_RELEASE" && ! "$EXPECTED_RELEASE" =~ ^R(81|82|8210)$ ]]; then
  die "--expected-release must be R81, R82, or R8210."
fi
if [[ -n "$CA_FILE" ]]; then
  [[ -f "$CA_FILE" ]] || die "Public CA file not found: $CA_FILE"
  CA_FILE="$(cd "$(dirname "$CA_FILE")" && pwd)/$(basename "$CA_FILE")"
  export CHECKPOINT_TLS_CA_FILE="$CA_FILE"
fi
ca_file_provided=false
[[ -n "$CA_FILE" ]] && ca_file_provided=true

require_cmd python3
outputs="$(load_terraform_outputs "$OUTPUTS_FILE")"
actual_release="$(
  printf '%s' "$outputs" |
    jq -e -r '.checkpoint_os_version.value'
)" || die "Terraform outputs do not contain checkpoint_os_version."
[[ "$actual_release" =~ ^R(81|82|8210)$ ]] ||
  die "Unsupported checkpoint_os_version in Terraform outputs: $actual_release"
if [[ -n "$EXPECTED_RELEASE" && "$actual_release" != "$EXPECTED_RELEASE" ]]; then
  die "Expected Check Point $EXPECTED_RELEASE, but deployment outputs report $actual_release."
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT/evidence/$(date -u +%Y%m%dT%H%M%SZ)-stage2"
elif [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$PWD/$OUTPUT_DIR"
fi
[[ ! -e "$OUTPUT_DIR/results.tsv" && ! -e "$OUTPUT_DIR/report.md" ]] ||
  die "Output directory already contains validation results: $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

printf '%s' "$outputs" |
  jq '
    with_entries(
      if (.value.sensitive // false)
      then .value.value = "<redacted>"
      else .
      end
    )
  ' >"$OUTPUT_DIR/deployment-outputs.json"
if [[ -n "$OUTPUTS_FILE" ]]; then
  outputs_source="outputs-file:${OUTPUTS_FILE##*/}"
else
  outputs_source="terraform-state"
fi
jq -n \
  --arg generatedUtc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg outputsSource "$outputs_source" \
  '{generatedUtc: $generatedUtc, outputsSource: $outputsSource}' \
  >"$OUTPUT_DIR/validation-metadata.json"
jq -n \
  --arg actualRelease "$actual_release" \
  --arg expectedRelease "${EXPECTED_RELEASE:-$actual_release}" \
  --argjson configurePolicy "$CONFIGURE_POLICY" \
  --argjson caFileProvided "$ca_file_provided" \
  '{
    actualRelease: $actualRelease,
    expectedRelease: $expectedRelease,
    configurePolicy: $configurePolicy,
    caFileProvided: $caFileProvided
  }' >"$OUTPUT_DIR/stage2-metadata.json"

commands_log="$OUTPUT_DIR/commands.log"
: >"$commands_log"
validation_exit_code=0
outputs_args=()
if [[ -n "$OUTPUTS_FILE" ]]; then
  outputs_args=(--outputs-file "$OUTPUTS_FILE")
fi

if $CONFIGURE_POLICY; then
  printf '$ CHECKPOINT_SKIP_POLICY_CONFIGURATION=false bash -x %q' \
    "$ROOT/scripts/configure-policy.sh" >>"$commands_log"
  if ((${#outputs_args[@]} > 0)); then
    printf ' %q' "${outputs_args[@]}" >>"$commands_log"
  fi
  printf '\n' >>"$commands_log"

  echo "Stage 2: configuring policies on the existing $actual_release deployment."
  set +e
  CHECKPOINT_SKIP_POLICY_CONFIGURATION=false \
    bash -x "$ROOT/scripts/configure-policy.sh" "${outputs_args[@]}" \
    >"$OUTPUT_DIR/configure-policy.log" 2>>"$commands_log"
  validation_exit_code=$?
  set -e
  if ((validation_exit_code != 0)); then
    echo "Policy configuration failed; generating a failure report." >&2
  fi
fi

if ((validation_exit_code == 0)); then
  printf '$ bash -x %q' "$ROOT/scripts/run-tests.sh" >>"$commands_log"
  if ((${#outputs_args[@]} > 0)); then
    printf ' %q' "${outputs_args[@]}" >>"$commands_log"
  fi
  printf ' --output-dir %q\n' "$OUTPUT_DIR" >>"$commands_log"

  echo "Stage 2: running automated validation against the existing deployment."
  set +e
  bash -x "$ROOT/scripts/run-tests.sh" \
    "${outputs_args[@]}" \
    --output-dir "$OUTPUT_DIR" \
    >"$OUTPUT_DIR/run-tests.log" 2>>"$commands_log"
  validation_exit_code=$?
  set -e
fi

python3 "$ROOT/scripts/render-test-report.py" \
  --evidence-dir "$OUTPUT_DIR" \
  --exit-code "$validation_exit_code"

echo "Stage-two report: $OUTPUT_DIR/report.md"
echo "Machine-readable summary: $OUTPUT_DIR/summary.json"
exit "$validation_exit_code"
