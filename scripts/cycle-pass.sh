#!/usr/bin/env bash
# Cycle pass gate. Reads _consolidated.json and decides whether the cycle advances.
#
# Pass criteria:
#   - critical-severity cluster count = 0
#   - disputed_severity = true count = 0
#
# Exit codes:
#   0 — cycle passes
#   1 — cycle fails (critical or disputed clusters present)
#   2 — usage error / missing artifact
#
# Usage: cycle-pass.sh <cycle-dir>
#   <cycle-dir> e.g. .forge/cycles/1

set -u
set -o pipefail

CYCLE_DIR="${1:-}"

if [[ -z "$CYCLE_DIR" ]]; then
  echo "Usage: cycle-pass.sh <cycle-dir>" >&2
  exit 2
fi

CONSOLIDATED="$CYCLE_DIR/_consolidated.json"

if [[ ! -f "$CONSOLIDATED" ]]; then
  echo "ERROR: $CONSOLIDATED not found" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found in PATH" >&2
  exit 2
fi

CRITICAL=$(jq '[.[] | select(.max_severity == "critical")] | length' "$CONSOLIDATED")
DISPUTED=$(jq '[.[] | select(.disputed_severity == true)] | length' "$CONSOLIDATED")
TOTAL=$(jq 'length' "$CONSOLIDATED")

echo "Cycle pass check: $CYCLE_DIR"
echo "  Total clusters:   $TOTAL"
echo "  Critical:         $CRITICAL  (must be 0)"
echo "  Disputed-severity: $DISPUTED (must be 0)"

if [[ "$CRITICAL" != "0" ]] || [[ "$DISPUTED" != "0" ]]; then
  echo ""
  echo "FAIL: cycle does not pass."
  if [[ "$CRITICAL" != "0" ]]; then
    echo ""
    echo "Critical clusters:"
    jq -r '.[] | select(.max_severity == "critical") | "  - \(.cluster_id): \(.title) [\(.file):\(.line_ranges | join(","))]"' "$CONSOLIDATED"
  fi
  if [[ "$DISPUTED" != "0" ]]; then
    echo ""
    echo "Disputed-severity clusters (max - min >= 2 levels):"
    jq -r '.[] | select(.disputed_severity == true) | "  - \(.cluster_id): \(.title) [max=\(.max_severity), min=\(.min_severity), reviewers=\(.reviewers | length)]"' "$CONSOLIDATED"
  fi
  exit 1
fi

echo ""
echo "PASS"
exit 0
