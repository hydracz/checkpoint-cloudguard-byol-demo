#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/migrate-tfvars.sh OLD_TFVARS [NEW_TFVARS]

Creates a new tfvars file without overwriting the source or an existing target.
When NEW_TFVARS is omitted, the target is OLD_TFVARS with .latest.tfvars added.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 2
fi

input="$1"
if [[ $# -eq 2 ]]; then
  output="$2"
elif [[ "$input" == *.tfvars ]]; then
  output="${input%.tfvars}.latest.tfvars"
else
  output="${input}.latest.tfvars"
fi

[[ -f "$input" ]] || {
  echo "ERROR: Old tfvars file not found: $input" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: Required command not found: python3" >&2
  exit 1
}

output_dir="$(dirname "$output")"
[[ -d "$output_dir" ]] || {
  echo "ERROR: Output directory not found: $output_dir" >&2
  exit 1
}

input_abs="$(cd "$(dirname "$input")" && pwd)/$(basename "$input")"
output_abs="$(cd "$output_dir" && pwd)/$(basename "$output")"
[[ "$input_abs" != "$output_abs" ]] || {
  echo "ERROR: Refusing in-place migration; choose a different output path." >&2
  exit 1
}
[[ ! -e "$output" ]] || {
  echo "ERROR: Refusing to overwrite existing output: $output" >&2
  exit 1
}

umask 077
temporary_file="$(mktemp "${output}.tmp.XXXXXX")"
trap 'rm -f "$temporary_file"' EXIT

python3 - "$input" >"$temporary_file" <<'PY'
import json
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    text = source.read()


def assignment_block(name):
    match = re.search(rf"(?m)^[ \t]*{re.escape(name)}[ \t]*=[ \t]*", text)
    if not match:
        return None

    value_start = match.end()
    if value_start >= len(text) or text[value_start] != "[":
        line_end = text.find("\n", value_start)
        return match.start(), len(text) if line_end < 0 else line_end + 1

    depth = 0
    in_string = False
    escaped = False
    in_comment = False
    index = value_start
    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""
        if in_comment:
            if char == "\n":
                in_comment = False
        elif in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "#" or (char == "/" and next_char == "/"):
            in_comment = True
            if char == "/":
                index += 1
        elif char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                line_end = text.find("\n", index)
                return match.start(), len(text) if line_end < 0 else line_end + 1
        index += 1
    raise SystemExit(f"Unclosed list assigned to {name}")


def strings_in_block(block):
    values = []
    index = 0
    in_comment = False
    while index < len(block):
        char = block[index]
        next_char = block[index + 1] if index + 1 < len(block) else ""
        if in_comment:
            if char == "\n":
                in_comment = False
            index += 1
            continue
        if char == "#" or (char == "/" and next_char == "/"):
            in_comment = True
            index += 2 if char == "/" else 1
            continue
        if char != '"':
            index += 1
            continue

        end = index + 1
        escaped = False
        while end < len(block):
            if escaped:
                escaped = False
            elif block[end] == "\\":
                escaped = True
            elif block[end] == '"':
                break
            end += 1
        if end >= len(block):
            raise SystemExit("Unclosed quoted string in legacy management settings")
        values.append(json.loads(block[index : end + 1]))
        index = end + 1
    return values


legacy_blocks = [
    block
    for block in (
        assignment_block("management_cidr"),
        assignment_block("ssh_source_cidrs"),
    )
    if block is not None
]
has_management_cidrs = bool(
    re.search(r"(?m)^[ \t]*management_cidrs[ \t]*=", text)
)

management_sources = []
for start, end in legacy_blocks:
    for value in strings_in_block(text[start:end]):
        if value not in management_sources:
            management_sources.append(value)

if legacy_blocks:
    replacement = ""
    if not has_management_cidrs and management_sources:
        entries = "\n".join(
            f"  {json.dumps(value, ensure_ascii=False)}," for value in management_sources
        )
        replacement = (
            "# Administrator sources for SSH, Gaia Portal, and SmartConsole.\n"
            f"management_cidrs = [\n{entries}\n]\n"
        )

    migrated = []
    cursor = 0
    first_start = min(start for start, _ in legacy_blocks)
    for start, end in sorted(legacy_blocks):
        migrated.append(text[cursor:start])
        if start == first_start:
            migrated.append(replacement)
        cursor = end
    migrated.append(text[cursor:])
    text = "".join(migrated)
    text = re.sub(
        r"(?m)^[ \t]*(?:#|//).*(?:management_cidr(?!s)\b|ssh_source_cidrs\b).*\n?",
        "",
        text,
    )

additions = []
if not re.search(r"(?m)^[ \t]*checkpoint_admin_password[ \t]*=", text):
    additions.append(
        "# Required: replace this placeholder with the Gaia admin password.\n"
        'checkpoint_admin_password = "REPLACE_ME"'
    )
if not re.search(r"(?m)^[ \t]*skip_policy_configuration[ \t]*=", text):
    additions.append(
        "# Keep Management API policy/rule automation disabled by default.\n"
        "skip_policy_configuration = true"
    )

if additions:
    if not text.endswith("\n"):
        text += "\n"
    if not text.endswith("\n\n"):
        text += "\n"
    text += "# Added for the current demo configuration.\n"
    text += "\n".join(additions)
    text += "\n"

sys.stdout.write(text)
PY

chmod 600 "$temporary_file"
mv "$temporary_file" "$output"
trap - EXIT

echo "Migrated tfvars written to: $output"
if grep -q '^[[:space:]]*checkpoint_admin_password[[:space:]]*=[[:space:]]*"REPLACE_ME"' "$output"; then
  echo "Replace checkpoint_admin_password = \"REPLACE_ME\" before running the deployment."
fi
