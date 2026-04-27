#!/usr/bin/env bash
# cycle-e2e-pass.sh — ship-gate for Phase F.
#
# Usage: cycle-e2e-pass.sh <e2e-dir>
#   <e2e-dir> typically is .forge/e2e/
#
# Exit 0 iff:
#   1. <e2e-dir>/_consolidated.json exists and has 0 clusters with
#      max_severity == "critical" or disputed_severity == true.
#   2. <e2e-dir>/scenarios.json exists and every scenario id has at least
#      one passing reviewer touch (i.e. some subagent-N.json contains a
#      finding whose evidence/description references that scenario id, OR
#      the consolidated artifact records a per-scenario coverage map).
#
# The "passing reviewer touch" predicate is intentionally loose — a strict
# coverage map is an enrichment for a future iteration. This script's job
# is to refuse ship on missing scenarios; reviewers' detailed verdicts
# live in the consolidated review.md (which the consolidator writes).
#
# Requires: jq.

set -u
set -o pipefail

E2E_DIR="${1:-}"
if [[ -z "$E2E_DIR" ]]; then
  echo "Usage: cycle-e2e-pass.sh <e2e-dir>" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 2
fi

CONS="${E2E_DIR}/_consolidated.json"
SCENARIOS="${E2E_DIR}/scenarios.json"

if [[ ! -f "$CONS" ]]; then
  echo "FAIL: $CONS missing" >&2
  exit 1
fi
if [[ ! -f "$SCENARIOS" ]]; then
  echo "FAIL: $SCENARIOS missing" >&2
  exit 1
fi

# 1) Critical / disputed clusters
critical=$(jq '[.[] | select(.max_severity == "critical")] | length' "$CONS" 2>/dev/null || echo "?")
disputed=$(jq '[.[] | select(.disputed_severity == true)] | length' "$CONS" 2>/dev/null || echo "?")

if [[ "$critical" != "0" || "$disputed" != "0" ]]; then
  echo "FAIL: e2e review has $critical critical and $disputed disputed clusters" >&2
  exit 1
fi

# 2) Every scenario id covered by some reviewer or in the consolidated artifact
# Collect scenario ids
ids=$(jq -r '.[].id' "$SCENARIOS" 2>/dev/null || true)
if [[ -z "$ids" ]]; then
  echo "FAIL: $SCENARIOS has no scenarios" >&2
  exit 1
fi

# Build the haystack — concatenate all reviewer JSON content + the
# consolidated artifact. We grep for each id within these texts.
HAYSTACK=$(mktemp)
trap 'rm -f "$HAYSTACK"' EXIT

# Reviewer outputs (if any)
if [[ -d "${E2E_DIR}/reviewers" ]]; then
  find "${E2E_DIR}/reviewers" -name 'subagent-*.json' -type f -print0 \
    | xargs -0 cat 2>/dev/null >> "$HAYSTACK" || true
fi
cat "$CONS" >> "$HAYSTACK" 2>/dev/null

uncovered=()
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  if ! grep -q -F "$id" "$HAYSTACK"; then
    uncovered+=("$id")
  fi
done <<< "$ids"

if (( ${#uncovered[@]} > 0 )); then
  echo "FAIL: scenarios not covered by any reviewer or consolidated cluster:" >&2
  for id in "${uncovered[@]}"; do
    echo "  - $id" >&2
  done
  exit 1
fi

echo "OK: e2e review has 0 critical, 0 disputed; all scenarios covered."
exit 0
