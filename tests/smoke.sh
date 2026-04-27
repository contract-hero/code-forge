#!/usr/bin/env bash
# Smoke test for code-forge-v2 orchestration scripts.
# Exits 0 iff every assertion passes; non-zero on first failure.
#
# Usage: bash tests/smoke.sh
#   Run from the plugin root, or from anywhere — the script resolves its own
#   location.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS="${PLUGIN_ROOT}/scripts"
FIXTURES="${SCRIPT_DIR}/fixtures"

PASSED=0
FAILED=0
FAILURES=()

assert() {
  local name="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: $name (expected '$expected', got '$actual')"
    FAILED=$((FAILED + 1))
    FAILURES+=("$name")
  fi
}

echo "=== code-forge-v2 smoke test ==="
echo "Plugin root: $PLUGIN_ROOT"
echo ""

# --- Environment checks ---
echo "Section 0: Environment"
command -v jq >/dev/null 2>&1
assert "jq present"           "$?" "0"
command -v node >/dev/null 2>&1
assert "node present"         "$?" "0"
echo ""

# --- cycle-validate.sh ---
echo "Section 1: cycle-validate.sh"
bash "${SCRIPTS}/cycle-validate.sh" "${FIXTURES}/cycle-good" >/dev/null 2>&1
assert "good fixture validates"          "$?" "0"

bash "${SCRIPTS}/cycle-validate.sh" "${FIXTURES}/cycle-bad-tests-schema" >/dev/null 2>&1
assert "bad-tests-schema fixture rejects" "$?" "1"
echo ""

# --- cycle-consolidate.mjs ---
echo "Section 2: cycle-consolidate.mjs"
node "${SCRIPTS}/cycle-consolidate.mjs" "${FIXTURES}/cycle-good/reviewers" >/dev/null 2>&1
assert "consolidate runs on good"         "$?" "0"

CONSOLIDATED="${FIXTURES}/cycle-good/_consolidated.json"
[[ -f "$CONSOLIDATED" ]]
assert "consolidated file written"        "$?" "0"

CLUSTER_COUNT=$(jq 'length' "$CONSOLIDATED" 2>/dev/null || echo "?")
[[ "$CLUSTER_COUNT" -ge 1 ]] && echo "  PASS: consolidated has $CLUSTER_COUNT clusters" && PASSED=$((PASSED + 1)) \
  || { echo "  FAIL: expected at least 1 cluster, got $CLUSTER_COUNT"; FAILED=$((FAILED + 1)); FAILURES+=("cluster count"); }
echo ""

# --- cycle-coverage.sh ---
echo "Section 3: cycle-coverage.sh"
bash "${SCRIPTS}/cycle-coverage.sh" "${FIXTURES}/cycle-good/reviewers" >/dev/null 2>&1
assert "coverage runs on good"            "$?" "0"
echo ""

# --- cycle-pass.sh ---
echo "Section 4: cycle-pass.sh"
bash "${SCRIPTS}/cycle-pass.sh" "${FIXTURES}/cycle-good" >/dev/null 2>&1
assert "good fixture passes"              "$?" "0"

# Build a disputed _consolidated.json on the fly (smaller than a full fixture)
DISPUTED_DIR="${FIXTURES}/cycle-bad-disputed"
mkdir -p "$DISPUTED_DIR"
cat > "${DISPUTED_DIR}/_consolidated.json" << 'JSON'
[
  {
    "cluster_id": "C001",
    "title": "Disputed severity test cluster",
    "file": "src/x.ts",
    "line_ranges": ["10-20"],
    "agreement_count": 2,
    "reviewers": [1, 3],
    "max_severity": "critical",
    "min_severity": "low",
    "disputed_severity": true,
    "categories": ["correctness"],
    "recommendations": ["pick one"],
    "descriptions": ["..."],
    "impacts": ["..."],
    "evidence": "...",
    "confidence_spread": ["high", "low"],
    "source_ids": ["R1-001", "R3-001"]
  }
]
JSON
bash "${SCRIPTS}/cycle-pass.sh" "${DISPUTED_DIR}" >/dev/null 2>&1
assert "disputed fixture fails"           "$?" "1"
echo ""

# --- cycle-tests-pass.sh red-phase exit-code inversion ---
echo "Section 5: cycle-tests-pass.sh (red-phase inversion)"
TMPDIR=$(mktemp -d)

# Tests that fail at red = phase passes (script exit 0)
bash "${SCRIPTS}/cycle-tests-pass.sh" red "$TMPDIR" -- bash -c "exit 1" >/dev/null 2>&1
assert "red phase: failing tests => exit 0"  "$?" "0"

# Tests that pass at red = phase fails (script exit 1)
bash "${SCRIPTS}/cycle-tests-pass.sh" red "$TMPDIR" -- bash -c "exit 0" >/dev/null 2>&1
assert "red phase: passing tests => exit 1"  "$?" "1"

# Green-phase passes through normally
bash "${SCRIPTS}/cycle-tests-pass.sh" green "$TMPDIR" -- bash -c "exit 0" >/dev/null 2>&1
assert "green phase: passing tests => exit 0"  "$?" "0"

bash "${SCRIPTS}/cycle-tests-pass.sh" green "$TMPDIR" -- bash -c "exit 1" >/dev/null 2>&1
assert "green phase: failing tests => exit 1"  "$?" "1"

rm -rf "$TMPDIR"
echo ""

# --- cycle-init.sh ---
echo "Section 6: cycle-init.sh"
INITDIR=$(mktemp -d)
bash "${SCRIPTS}/cycle-init.sh" "${INITDIR}/cycle-99" >/dev/null 2>&1
assert "cycle-init runs"                  "$?" "0"
[[ -f "${INITDIR}/cycle-99/contract.md" ]]
assert "contract.md scaffolded"           "$?" "0"
[[ -f "${INITDIR}/cycle-99/tests.json" ]]
assert "tests.json scaffolded"            "$?" "0"
[[ -d "${INITDIR}/cycle-99/reviewers" ]]
assert "reviewers/ scaffolded"            "$?" "0"
rm -rf "$INITDIR"
echo ""

# --- forge-status.sh (smoke check — just ensure it runs) ---
echo "Section 7: forge-status.sh"
bash "${SCRIPTS}/forge-status.sh" "${FIXTURES}/cycle-good" >/dev/null 2>&1 || true
# Non-zero is fine; we just want it not to crash badly. Check via grep instead.
OUT=$(bash "${SCRIPTS}/forge-status.sh" "${FIXTURES}/cycle-good" 2>/dev/null || true)
echo "$OUT" | grep -q "Forge Status"
assert "forge-status emits header"        "$?" "0"
echo ""

# --- Cleanup transient outputs ---
rm -f "${FIXTURES}/cycle-good/_consolidated.json"
rm -f "${FIXTURES}/cycle-bad-disputed/_consolidated.json"
rmdir "${FIXTURES}/cycle-bad-disputed" 2>/dev/null || true

# --- Summary ---
echo "=== Smoke summary ==="
echo "  Passed: $PASSED"
echo "  Failed: $FAILED"
if [[ "$FAILED" != "0" ]]; then
  echo ""
  echo "Failed assertions:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
