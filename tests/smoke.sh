#!/usr/bin/env bash
# Smoke test for code-forge v0.2.0 (Option D).
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
HOOK="${PLUGIN_ROOT}/hooks/forge-guard.mjs"
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

# Stand up a temp dir with a green-phase .forge/ scaffolding for hook tests.
# Args: $1 test_file path; $2 optional target_file (default src/foo.ts).
# Echoes the temp dir path; caller is responsible for `rm -rf` cleanup.
setup_green_phase_fixture() {
  local test_file="$1"
  local target_file="${2:-src/foo.ts}"
  local dir
  dir=$(mktemp -d)
  mkdir -p "${dir}/.forge/cycles/1"
  cat > "${dir}/.forge/state.json" << 'JSON'
{ "phase": "green", "current_cycle": 1 }
JSON
  printf '[{"id":"T-001","name":"x","behavior":"x","kind":"unit","target_file":"%s","test_file":"%s"}]\n' \
    "$target_file" "$test_file" > "${dir}/.forge/cycles/1/tests.json"
  echo "$dir"
}

echo "=== code-forge smoke test (Option D) ==="
echo "Plugin root: $PLUGIN_ROOT"
echo ""

# --- Environment checks ---
echo "Section 0: Environment"
command -v jq >/dev/null 2>&1
assert "jq present"           "$?" "0"
command -v node >/dev/null 2>&1
assert "node present"         "$?" "0"
[[ -x "${SCRIPTS}/forge.sh" ]]
assert "forge.sh executable"  "$?" "0"
[[ -f "${PLUGIN_ROOT}/templates/spec.md.template" ]]
assert "spec.md.template present" "$?" "0"
[[ -f "${PLUGIN_ROOT}/docs/goal-integration.md" ]]
assert "docs/goal-integration.md present" "$?" "0"
echo ""

# --- cycle-validate.sh ---
echo "Section 1: cycle-validate.sh"
bash "${SCRIPTS}/cycle-validate.sh" "${FIXTURES}/cycle-good" >/dev/null 2>&1
assert "good fixture validates"          "$?" "0"

bash "${SCRIPTS}/cycle-validate.sh" "${FIXTURES}/cycle-bad-tests-schema" >/dev/null 2>&1
assert "bad-tests-schema fixture rejects" "$?" "1"
echo ""

# --- F2: sed portability — reviewer-index extraction round-trip ---
# Regression guard for the GNU-vs-BSD sed-ism on macOS.
echo "Section 2: sed portability"
n=$(basename "${FIXTURES}/cycle-good/reviewers/subagent-3.json" \
    | sed -n 's/^subagent-\([0-9][0-9]*\)\.json$/\1/p')
[[ "$n" == "3" ]]
assert "reviewer-index extraction is non-empty on macOS" "$?" "0"
echo ""

# --- cycle-tests-pass.sh red-phase exit-code inversion ---
echo "Section 3: cycle-tests-pass.sh (red-phase inversion)"
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
echo "Section 4: cycle-init.sh"
INITDIR=$(mktemp -d)
bash "${SCRIPTS}/cycle-init.sh" "${INITDIR}/cycle-C1" >/dev/null 2>&1
assert "cycle-init runs"                       "$?" "0"
[[ -f "${INITDIR}/cycle-C1/tests.json" ]]
assert "tests.json scaffolded"                 "$?" "0"
[[ -d "${INITDIR}/cycle-C1/reviewers" ]]
assert "reviewers/ scaffolded"                 "$?" "0"
[[ -d "${INITDIR}/cycle-C1/green/candidates" ]]
assert "green/candidates/ scaffolded"          "$?" "0"
# Option D: cycle-init no longer scaffolds contract.md
[[ ! -f "${INITDIR}/cycle-C1/contract.md" ]]
assert "no contract.md scaffolded (Option D)"  "$?" "0"
rm -rf "$INITDIR"
echo ""

# --- forge-status.sh ---
echo "Section 5: forge-status.sh"
OUT=$(bash "${SCRIPTS}/forge-status.sh" "${FIXTURES}/cycle-good" 2>/dev/null || true)
echo "$OUT" | grep -q "Forge Status"
assert "forge-status emits header"             "$?" "0"
echo ""

# --- pre-cycle artifact validators ---
echo "Section 6: pre-cycle validators"
PC_DIR=$(mktemp -d)

# Empty plan.md → reject
: > "${PC_DIR}/plan.md"
bash "${SCRIPTS}/cycle-validate.sh" "${PC_DIR}/plan.md" >/dev/null 2>&1
assert "empty plan.md rejects"                 "$?" "1"

# Non-empty plan.md → accept
echo -e "# Plan\n\nDoes things." > "${PC_DIR}/plan.md"
bash "${SCRIPTS}/cycle-validate.sh" "${PC_DIR}/plan.md" >/dev/null 2>&1
assert "non-empty plan.md validates"           "$?" "0"

# Spec without ## Cycle Plan → reject (Option D requires the block)
cat > "${PC_DIR}/spec.md" << 'SPECMD'
# Project Spec

## Vision
Do things.

## Architecture
Use code.
SPECMD
bash "${SCRIPTS}/cycle-validate.sh" "${PC_DIR}/spec.md" >/dev/null 2>&1
assert "spec without Cycle Plan rejects"       "$?" "1"

# Spec with ## Cycle Plan and ## Reviewer Config → accept
cat >> "${PC_DIR}/spec.md" << 'SPECMD'

## E2E Tests
- E-001: thing happens

## Cycle Plan
- id: C1
  goal: bootstrap
  files_affected: [src/foo.ts]
  acceptance: [AC-001]

## Reviewer Config
model: opus
dimensions:
  - correctness
SPECMD
bash "${SCRIPTS}/cycle-validate.sh" "${PC_DIR}/spec.md" >/dev/null 2>&1
assert "spec with Cycle Plan + Reviewer Config validates" "$?" "0"

rm -rf "${PC_DIR}"
echo ""

# --- agent-config.md schema ---
echo "Section 7: agent-config.md schema"
bash "${SCRIPTS}/cycle-validate.sh" "${FIXTURES}/cycle-good/agent-config.md" >/dev/null 2>&1
assert "greenfield agent-config validates"     "$?" "0"

bash "${SCRIPTS}/cycle-validate.sh" "${FIXTURES}/cycle-good-sui/agent-config.md" >/dev/null 2>&1
assert "sui agent-config validates"            "$?" "0"

# Missing frontmatter → reject
BAD_AC_DIR=$(mktemp -d)
echo "no frontmatter here" > "${BAD_AC_DIR}/agent-config.md"
bash "${SCRIPTS}/cycle-validate.sh" "${BAD_AC_DIR}/agent-config.md" >/dev/null 2>&1
assert "missing-frontmatter agent-config rejects" "$?" "1"
rm -rf "$BAD_AC_DIR"
echo ""

# --- best-of-N fixture (still relevant in Option D) ---
echo "Section 8: best-of-N fixture"
BON="${FIXTURES}/cycle-good-with-best-of-n"

bash "${SCRIPTS}/cycle-validate.sh" "${BON}/tests.json" >/dev/null 2>&1
assert "best-of-N tests.json validates"        "$?" "0"

# All six worker manifests exist
worker_count=$(find "${BON}/green/candidates" -mindepth 1 -maxdepth 1 -type d -name 'worker-*' | wc -l | tr -d ' ')
[[ "$worker_count" == "6" ]]
assert "best-of-N has 6 worker dirs"           "$?" "0"

manifest_count=$(find "${BON}/green/candidates" -name manifest.json | wc -l | tr -d ' ')
[[ "$manifest_count" == "6" ]]
assert "best-of-N has 6 manifests"             "$?" "0"

# Coordinator pick metric: chosen worker's manifest claims tests_pass=true
chosen_pass=$(jq -r '.tests_pass' "${BON}/green/candidates/worker-4/manifest.json")
[[ "$chosen_pass" == "true" ]]
assert "chosen worker passes tests"            "$?" "0"
echo ""

# --- forge-guard rule 5: test-file edit during green ---
echo "Section 9: forge-guard rule 5 — test-file immutability"
R5_DIR=$(setup_green_phase_fixture "tests/foo.test.ts")

# Hook BLOCKS Edit on a test_file path during green
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${R5_DIR}/tests/foo.test.ts\"}}" \
  | (cd "${R5_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "blocks edit on test_file"              "$?" "2"

# Hook ALLOWS Edit on a target_file source path during green
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${R5_DIR}/src/foo.ts\"}}" \
  | (cd "${R5_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "allows edit on target_file"            "$?" "0"

# Schema validation rejects tests.json missing test_file
printf '[{"id":"T-001","name":"x","behavior":"x","kind":"unit","target_file":"src/foo.ts"}]\n' \
  > "${R5_DIR}/.forge/cycles/1/tests.json"
bash "${SCRIPTS}/cycle-validate.sh" "${R5_DIR}/.forge/cycles/1/tests.json" >/dev/null 2>&1
assert "tests.json without test_file rejects"  "$?" "1"

rm -rf "$R5_DIR"
echo ""

# --- candidate-staging prefix peel ---
echo "Section 10: worker candidate-staging prefix peel"
F4_DIR=$(setup_green_phase_fixture "test/strip-ansi.test.ts" "src/strip-ansi.ts")
mkdir -p "${F4_DIR}/.forge/cycles/1/green/candidates/worker-3/files"

# Worker writing to a test_file path inside its candidate dir → BLOCK
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${F4_DIR}/.forge/cycles/1/green/candidates/worker-3/files/test/strip-ansi.test.ts\"}}" \
  | (cd "${F4_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "blocks worker test-file edit"          "$?" "2"

# Worker writing to a target_file source path inside its candidate dir → ALLOW
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${F4_DIR}/.forge/cycles/1/green/candidates/worker-3/files/src/strip-ansi.ts\"}}" \
  | (cd "${F4_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "allows worker source edit"             "$?" "0"

rm -rf "$F4_DIR"
echo ""

# --- realpath path normalization (macOS /var → /private/var) ---
echo "Section 11: realpath normalization (macOS symlink crossing)"
F11_DIR=$(setup_green_phase_fixture "tests/foo.test.ts")
F11_REAL=$(cd "$F11_DIR" && pwd -P)
if [[ "$F11_DIR" == "$F11_REAL" ]]; then
  echo "  SKIP: no symlink in temp-dir path; nothing to exercise here"
else
  echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${F11_DIR}/tests/foo.test.ts\"}}" \
    | (cd "${F11_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
  assert "blocks across /var symlink"          "$?" "2"
fi
rm -rf "$F11_DIR"
echo ""

# --- Bash file-writes during green (F10) ---
echo "Section 12: Bash file-writes blocked during green"
F10_DIR=$(setup_green_phase_fixture "tests/foo.test.ts" "src/foo.ts")

echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo trivial > tests/foo.test.ts\"}}" \
  | (cd "${F10_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "Bash > to test_file blocks"            "$?" "2"

echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo extra >> tests/foo.test.ts\"}}" \
  | (cd "${F10_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "Bash >> to test_file blocks"           "$?" "2"

echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp src/something tests/foo.test.ts\"}}" \
  | (cd "${F10_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "Bash cp to test_file blocks"           "$?" "2"

echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i 's/expect/skip/' tests/foo.test.ts\"}}" \
  | (cd "${F10_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "Bash sed -i on test_file blocks"       "$?" "2"

echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo content > src/foo.ts\"}}" \
  | (cd "${F10_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "Bash > to source path allows"          "$?" "0"

echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"pnpm test\"}}" \
  | (cd "${F10_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "Bash with no write target allows"      "$?" "0"

rm -rf "$F10_DIR"
echo ""

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
