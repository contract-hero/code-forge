#!/usr/bin/env bash
# Scaffold a cycle directory with empty schema-valid stubs.
# Run at the start of each cycle to give phase agents a known-shape tree.
# Also (re-)derives _scope_files.txt from contract.md's "## Files" section
# whenever a contract is present.
#
# Usage: cycle-init.sh <cycle-dir>
#   <cycle-dir> e.g. .forge/cycles/1
#
# Creates / refreshes:
#   <cycle-dir>/
#     contract.md             (placeholder with required H2 sections, if missing)
#     tests.json              (empty array — schema-valid, if missing)
#     reviewers/              (directory)
#     _scope_files.txt        (derived from contract.md's "## Files" section
#                              if a real contract is present; empty otherwise)
#
# Idempotent: if files already exist, leaves them alone EXCEPT _scope_files.txt
# which is always (re-)derived from contract.md when the contract has filled-in
# bullets in its "## Files" section.

set -u
set -o pipefail

CYCLE_DIR="${1:-}"

if [[ -z "$CYCLE_DIR" ]]; then
  echo "Usage: cycle-init.sh <cycle-dir>" >&2
  exit 2
fi

mkdir -p "$CYCLE_DIR/reviewers"

if [[ ! -f "$CYCLE_DIR/contract.md" ]]; then
  cat > "$CYCLE_DIR/contract.md" << 'TEMPLATE'
# Cycle Contract

<!-- Replace this placeholder with the cycle's contract. The three H2 sections
     below are required by cycle-validate.sh. -->

## Behavior

What this cycle delivers, in user-facing terms. One paragraph.

## Files

- path/to/file.ext — what this file does after this cycle

## Acceptance

- Concrete acceptance criterion 1 (testable)
- Concrete acceptance criterion 2
TEMPLATE
  echo "Created $CYCLE_DIR/contract.md (placeholder)"
fi

if [[ ! -f "$CYCLE_DIR/tests.json" ]]; then
  echo "[]" > "$CYCLE_DIR/tests.json"
  echo "Created $CYCLE_DIR/tests.json (empty array)"
fi

# Derive _scope_files.txt from contract.md's "## Files" section.
# Format expected: "- path/to/file.ext — description" (em-dash or hyphen tolerated).
# We extract the first whitespace-delimited token after the leading bullet.
# Skip the placeholder example line "path/to/file.ext".
SCOPE="$CYCLE_DIR/_scope_files.txt"
CONTRACT="$CYCLE_DIR/contract.md"

if [[ -f "$CONTRACT" ]]; then
  awk '
    BEGIN { inFiles = 0 }
    /^## Files[[:space:]]*$/ { inFiles = 1; next }
    /^## / && inFiles { inFiles = 0 }
    inFiles && /^[[:space:]]*-[[:space:]]+/ {
      # strip leading "- " then take the first token
      line = $0
      sub(/^[[:space:]]*-[[:space:]]+/, "", line)
      n = split(line, parts, /[[:space:]]+/)
      if (n > 0) {
        path = parts[1]
        # skip the placeholder
        if (path != "path/to/file.ext") {
          print path
        }
      }
    }
  ' "$CONTRACT" > "$SCOPE"

  if [[ -s "$SCOPE" ]]; then
    LINES=$(wc -l < "$SCOPE" | tr -d ' ')
    echo "Derived $SCOPE from contract.md ($LINES files)"
  else
    echo "Warning: contract.md's '## Files' section has no concrete bullets — $SCOPE is empty"
  fi
else
  : > "$SCOPE"
  echo "Created $SCOPE (empty — no contract.md to derive from)"
fi

echo ""
echo "Cycle scaffolded: $CYCLE_DIR"
echo "  contract.md       — fill in the three H2 sections"
echo "  tests.json        — test-author phase will populate"
echo "  reviewers/        — consolidated-review phase will populate with subagent-*.json"
echo "  _scope_files.txt  — derived from contract; re-run cycle-init.sh after editing contract"
