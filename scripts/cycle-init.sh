#!/usr/bin/env bash
# Scaffold a cycle directory with empty schema-valid stubs.
# Run by the cycle child at the start of each cycle.
#
# Usage: cycle-init.sh <cycle-dir>
#   <cycle-dir> e.g. .forge/cycles/C1
#
# Creates / refreshes:
#   <cycle-dir>/
#     tests.json   (empty array — schema-valid, if missing)
#     reviewers/   (directory)
#     green/       (directory for best-of-N candidate dirs)
#
# Idempotent: if files already exist, leaves them alone.
#
# In Option D there is no contract.md (folded into spec.md ## Cycle Plan)
# and no _scope_files.txt (no longer needed — forge-guard reads
# tests.json directly). The scaffolding is intentionally minimal.

set -u
set -o pipefail

CYCLE_DIR="${1:-}"

if [[ -z "$CYCLE_DIR" ]]; then
  echo "Usage: cycle-init.sh <cycle-dir>" >&2
  exit 2
fi

mkdir -p "$CYCLE_DIR/reviewers" "$CYCLE_DIR/green/candidates"

if [[ ! -f "$CYCLE_DIR/tests.json" ]]; then
  echo "[]" > "$CYCLE_DIR/tests.json"
  echo "Created $CYCLE_DIR/tests.json (empty array)"
fi

echo ""
echo "Cycle scaffolded: $CYCLE_DIR"
echo "  tests.json       — test-author will populate"
echo "  reviewers/       — reviewers fan out their subagent-*.json here"
echo "  green/candidates — best-of-N workers stage their candidate files here"
