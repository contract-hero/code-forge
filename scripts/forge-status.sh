#!/usr/bin/env bash
# Print a human-readable progress dashboard for the current forge run.
# Reads .forge/state.json and cycles/* and summarizes phase, gate status, retries.
#
# Usage: forge-status.sh [<forge-dir>]
#   <forge-dir> defaults to .forge

set -u
set -o pipefail

FORGE_DIR="${1:-.forge}"

if [[ ! -d "$FORGE_DIR" ]]; then
  echo "No forge run found at $FORGE_DIR" >&2
  exit 1
fi

echo "=== Forge Status — $FORGE_DIR ==="
echo ""

# Top-level state
if [[ -f "$FORGE_DIR/state.json" ]]; then
  if command -v jq >/dev/null 2>&1; then
    PHASE=$(jq -r '.phase // "?"' "$FORGE_DIR/state.json" 2>/dev/null || echo "?")
    CYCLE=$(jq -r '.current_cycle // "?"' "$FORGE_DIR/state.json" 2>/dev/null || echo "?")
    CYC_STATUS=$(jq -r '.cycle_status // "?"' "$FORGE_DIR/state.json" 2>/dev/null || echo "?")
    ITER=$(jq -r '.iteration // 0' "$FORGE_DIR/state.json" 2>/dev/null || echo "0")
    TOTAL=$(jq -r '.total_cycles // "?"' "$FORGE_DIR/state.json" 2>/dev/null || echo "?")
    echo "Top-level state:"
    echo "  phase:          $PHASE"
    echo "  current_cycle:  $CYCLE / $TOTAL"
    echo "  cycle_status:   $CYC_STATUS"
    echo "  iteration:      $ITER"
  else
    echo "(jq not installed; raw state.json:)"
    cat "$FORGE_DIR/state.json"
  fi
else
  echo "(no state.json found)"
fi

echo ""
echo "Phase artifacts (top-level):"
for art in intent.md spec.md cycle-plan.md final-review.md; do
  if [[ -f "$FORGE_DIR/$art" ]]; then
    LINES=$(wc -l < "$FORGE_DIR/$art" | tr -d ' ')
    echo "  ✓ $art ($LINES lines)"
  else
    echo "  ✗ $art"
  fi
done

echo ""
echo "Cycles:"
if [[ -d "$FORGE_DIR/cycles" ]]; then
  for cd in "$FORGE_DIR"/cycles/*/; do
    [[ -d "$cd" ]] || continue
    n=$(basename "$cd")
    echo ""
    echo "  Cycle $n: $cd"
    for art in contract.md tests.json _consolidated.json review.md; do
      if [[ -f "$cd$art" ]]; then
        echo "    ✓ $art"
      else
        echo "    ✗ $art"
      fi
    done
    if [[ -f "$cd/red.json" ]] && command -v jq >/dev/null 2>&1; then
      RED_EXIT=$(jq -r '.exit_code' "$cd/red.json" 2>/dev/null || echo "?")
      echo "    red.json:    exit=$RED_EXIT (expected non-zero)"
    fi
    if [[ -f "$cd/green.json" ]] && command -v jq >/dev/null 2>&1; then
      GREEN_EXIT=$(jq -r '.exit_code' "$cd/green.json" 2>/dev/null || echo "?")
      echo "    green.json:  exit=$GREEN_EXIT (expected 0)"
    fi
    if [[ -f "$cd/_consolidated.json" ]] && command -v jq >/dev/null 2>&1; then
      CLUST=$(jq 'length' "$cd/_consolidated.json" 2>/dev/null || echo "?")
      CRIT=$(jq '[.[] | select(.max_severity == "critical")] | length' "$cd/_consolidated.json" 2>/dev/null || echo "?")
      DISP=$(jq '[.[] | select(.disputed_severity == true)] | length' "$cd/_consolidated.json" 2>/dev/null || echo "?")
      echo "    consolidated: $CLUST clusters (critical=$CRIT, disputed=$DISP)"
    fi
    if [[ -d "$cd/reviewers" ]]; then
      JSONS=$(find "$cd/reviewers" -name 'subagent-*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
      echo "    reviewers:   $JSONS subagent-*.json files"
    fi
  done
else
  echo "  (no cycles/ dir yet)"
fi

echo ""
echo "Run /forge-smoke to validate the plugin's own scripts."
