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
SKIPPED=0
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

# Convenience: feed a PreToolUse payload to the hook and assert exit code.
run_hook() {
  local label="$1"
  local payload="$2"
  local expected="$3"
  local dir="${4:-$(pwd)}"
  echo "$payload" | (cd "$dir" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
  assert "$label" "$?" "$expected"
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

# --- cycle-tests-pass.sh red-phase exit-code inversion + meta-JSON shape ---
echo "Section 3: cycle-tests-pass.sh (red-phase inversion + meta schema)"
TMPDIR=$(mktemp -d)

# Tests that fail at red = phase passes (script exit 0)
bash "${SCRIPTS}/cycle-tests-pass.sh" red "$TMPDIR" -- bash -c "echo 'FAIL: assertion'; exit 1" >/dev/null 2>&1
assert "red phase: failing tests => exit 0"  "$?" "0"

# red.json shape: phase + exit_code (number) + phase_pass (boolean) + command
red_meta_ok=$(jq -e '
  .phase == "red" and
  (.exit_code | type == "number") and
  (.phase_pass | type == "boolean") and
  (.command | type == "string") and (.command != "") and
  (.started_at | type == "string") and
  (.ended_at | type == "string")
' "$TMPDIR/red.json" >/dev/null 2>&1 && echo ok || echo bad)
assert "red.json meta schema valid"          "$red_meta_ok" "ok"

# Tests that pass at red = phase fails (script exit 1)
bash "${SCRIPTS}/cycle-tests-pass.sh" red "$TMPDIR" -- bash -c "exit 0" >/dev/null 2>&1
assert "red phase: passing tests => exit 1"  "$?" "1"

# Green-phase passes through normally
bash "${SCRIPTS}/cycle-tests-pass.sh" green "$TMPDIR" -- bash -c "exit 0" >/dev/null 2>&1
assert "green phase: passing tests => exit 0"  "$?" "0"

green_meta_ok=$(jq -e '
  .phase == "green" and (.exit_code | type == "number") and
  (.phase_pass | type == "boolean") and (.command | type == "string")
' "$TMPDIR/green.json" >/dev/null 2>&1 && echo ok || echo bad)
assert "green.json meta schema valid"        "$green_meta_ok" "ok"

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

# Spec with all required sections → accept
cat >> "${PC_DIR}/spec.md" << 'SPECMD'

## Acceptance Criteria
- AC-001: thing must happen

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

# Every passer must have tests_pass=true, lines_changed an int, target_files a list.
# (Verifies the manifest schema the cycle child's pick logic depends on.)
manifest_shape_ok=$(jq -e '
  .tests_pass != null and (.tests_pass | type == "boolean") and
  .lines_changed != null and (.lines_changed | type == "number") and
  .target_files != null and (.target_files | type == "array")
' "${BON}/green/candidates/worker-4/manifest.json" >/dev/null 2>&1 && echo ok || echo bad)
assert "worker manifest shape valid"           "$manifest_shape_ok" "ok"
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
  SKIPPED=$((SKIPPED + 1))
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

# --- Section 13: anchor-file protection (state.json + tests.json themselves) ---
echo "Section 13: anchor-file protection during green"
A_DIR=$(setup_green_phase_fixture "tests/foo.test.ts")

# state.json itself must NOT be writable during green (would disable rule 5)
run_hook "blocks Edit on state.json" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${A_DIR}/.forge/state.json\"}}" \
  "2" "$A_DIR"

# tests.json itself must NOT be writable during green
run_hook "blocks Edit on tests.json" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${A_DIR}/.forge/cycles/1/tests.json\"}}" \
  "2" "$A_DIR"

# Bash writes to anchors also blocked
run_hook "blocks Bash > to state.json" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > .forge/state.json\"}}" \
  "2" "$A_DIR"

# A worker can't write state.json via candidate-staging either
mkdir -p "${A_DIR}/.forge/cycles/1/green/candidates/worker-1/files/.forge"
run_hook "blocks state.json edit via candidate staging" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${A_DIR}/.forge/cycles/1/green/candidates/worker-1/files/.forge/state.json\"}}" \
  "2" "$A_DIR"

rm -rf "$A_DIR"
echo ""

# --- Section 14: hook is conditional on phase=green (non-green allows) ---
echo "Section 14: non-green phase allows test-file edit"
NG_DIR=$(mktemp -d)
mkdir -p "${NG_DIR}/.forge/cycles/1"
cat > "${NG_DIR}/.forge/state.json" << 'JSON'
{ "phase": "test-list", "current_cycle": 1 }
JSON
printf '[{"id":"T-001","name":"x","behavior":"x","kind":"unit","target_file":"src/foo.ts","test_file":"tests/foo.test.ts"}]\n' \
  > "${NG_DIR}/.forge/cycles/1/tests.json"

run_hook "allows test_file edit in test-list phase" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${NG_DIR}/tests/foo.test.ts\"}}" \
  "0" "$NG_DIR"

# No state.json at all → no green phase → allow.
NG2_DIR=$(mktemp -d)
mkdir -p "${NG2_DIR}/tests"
run_hook "allows edit when no state.json (out of .forge)" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${NG2_DIR}/tests/foo.test.ts\"}}" \
  "0" "$NG2_DIR"

rm -rf "$NG_DIR" "$NG2_DIR"
echo ""

# --- Section 15: hook fail-closed on malformed state.json / tests.json ---
echo "Section 15: hook fail-closed on malformed anchor files"
M_DIR=$(setup_green_phase_fixture "tests/foo.test.ts")
echo "not json" > "${M_DIR}/.forge/state.json"
run_hook "malformed state.json → block (fail-closed)" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${M_DIR}/src/foo.ts\"}}" \
  "2" "$M_DIR"

# Restore a valid green state but corrupt tests.json
cat > "${M_DIR}/.forge/state.json" << 'JSON'
{ "phase": "green", "current_cycle": 1 }
JSON
echo "{bad" > "${M_DIR}/.forge/cycles/1/tests.json"
run_hook "malformed tests.json → block (fail-closed)" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${M_DIR}/src/foo.ts\"}}" \
  "2" "$M_DIR"

rm -rf "$M_DIR"
echo ""

# --- Section 16: Bash side-door extensions (BSD sed, &>, >|, cp -t, perl, ln, truncate) ---
echo "Section 16: extended Bash side-door coverage"
E_DIR=$(setup_green_phase_fixture "tests/foo.test.ts" "src/foo.ts")

run_hook "BSD sed -i '' blocks"   "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i '' 's/x/y/' tests/foo.test.ts\"}}" "2" "$E_DIR"
run_hook "&> redirect blocks"      "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo trivial &> tests/foo.test.ts\"}}" "2" "$E_DIR"
run_hook ">| clobber blocks"       "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo trivial >| tests/foo.test.ts\"}}" "2" "$E_DIR"
run_hook "2> redirect blocks"      "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"some_cmd 2> tests/foo.test.ts\"}}" "2" "$E_DIR"
run_hook "cp -t form blocks"       "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp -t tests/ src/a tests/foo.test.ts\"}}" "2" "$E_DIR"
run_hook "perl -i blocks"          "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"perl -i -pe 's/x/y/' tests/foo.test.ts\"}}" "2" "$E_DIR"
run_hook "awk -i inplace blocks"   "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"awk -i inplace '{print}' tests/foo.test.ts\"}}" "2" "$E_DIR"
run_hook "truncate blocks"         "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"truncate -s 0 tests/foo.test.ts\"}}" "2" "$E_DIR"
run_hook "ln -sf blocks"           "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ln -sf /dev/null tests/foo.test.ts\"}}" "2" "$E_DIR"
run_hook "rm blocks"               "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm tests/foo.test.ts\"}}" "2" "$E_DIR"
run_hook "bash -c with test path blocks" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -c 'echo y > tests/foo.test.ts'\"}}" "2" "$E_DIR"
run_hook "sh -c with test path blocks"   "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sh -c 'cp src/a tests/foo.test.ts'\"}}" "2" "$E_DIR"
run_hook "eval with test path blocks"    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"eval \\\"echo y > tests/foo.test.ts\\\"\"}}" "2" "$E_DIR"

# Negative: write to a SOURCE path with bash -c is allowed.
run_hook "bash -c to source allows"   "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash -c 'echo y > src/foo.ts'\"}}" "0" "$E_DIR"

rm -rf "$E_DIR"
echo ""

# --- Section 17: C1-style cycle id (string id) blocks correctly ---
echo "Section 17: string cycle id (C1) works with candidate-staging peel"
C_DIR=$(mktemp -d)
mkdir -p "${C_DIR}/.forge/cycles/C1"
cat > "${C_DIR}/.forge/state.json" << 'JSON'
{ "phase": "green", "current_cycle": "C1" }
JSON
printf '[{"id":"T-001","name":"x","behavior":"x","kind":"unit","target_file":"src/foo.ts","test_file":"tests/foo.test.ts"}]\n' \
  > "${C_DIR}/.forge/cycles/C1/tests.json"
mkdir -p "${C_DIR}/.forge/cycles/C1/green/candidates/worker-3/files"

run_hook "blocks edit on test_file (C1)"  \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${C_DIR}/tests/foo.test.ts\"}}" \
  "2" "$C_DIR"
run_hook "blocks worker test-file edit (C1)" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${C_DIR}/.forge/cycles/C1/green/candidates/worker-3/files/tests/foo.test.ts\"}}" \
  "2" "$C_DIR"
run_hook "allows worker source edit (C1)" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${C_DIR}/.forge/cycles/C1/green/candidates/worker-3/files/src/foo.ts\"}}" \
  "0" "$C_DIR"

rm -rf "$C_DIR"
echo ""

# --- Section 18: result.json validator (positive + negative) ---
echo "Section 18: result.json schema validation"
R_DIR=$(mktemp -d)

# Positive
cat > "${R_DIR}/result.json" << 'JSON'
{
  "cycle_id": "C1",
  "status": "pass",
  "summary": "all tests pass; 0 critical findings",
  "winner_worker": "W3",
  "review_clusters": { "critical": 0, "high": 2, "medium": 5, "low": 3, "info": 0 },
  "started_at": "2026-05-19T10:00:00Z",
  "ended_at":   "2026-05-19T10:24:00Z"
}
JSON
bash "${SCRIPTS}/cycle-validate.sh" "${R_DIR}/result.json" >/dev/null 2>&1
assert "good result.json validates"            "$?" "0"

# Negative: missing status
cat > "${R_DIR}/result.json" << 'JSON'
{ "cycle_id": "C1", "summary": "x", "review_clusters": { "critical": 0, "high": 0 } }
JSON
bash "${SCRIPTS}/cycle-validate.sh" "${R_DIR}/result.json" >/dev/null 2>&1
assert "result.json without status rejects"    "$?" "1"

# Negative: invalid status value
cat > "${R_DIR}/result.json" << 'JSON'
{ "cycle_id": "C1", "status": "ok", "summary": "x", "review_clusters": { "critical": 0, "high": 0 } }
JSON
bash "${SCRIPTS}/cycle-validate.sh" "${R_DIR}/result.json" >/dev/null 2>&1
assert "result.json with bad status rejects"   "$?" "1"

# Negative: review_clusters is the wrong shape (array, not object)
cat > "${R_DIR}/result.json" << 'JSON'
{ "cycle_id": "C1", "status": "pass", "summary": "x", "review_clusters": [] }
JSON
bash "${SCRIPTS}/cycle-validate.sh" "${R_DIR}/result.json" >/dev/null 2>&1
assert "result.json with array review_clusters rejects" "$?" "1"

# Negative: status pass but critical > 0
cat > "${R_DIR}/result.json" << 'JSON'
{ "cycle_id": "C1", "status": "pass", "summary": "x", "review_clusters": { "critical": 3, "high": 0 } }
JSON
bash "${SCRIPTS}/cycle-validate.sh" "${R_DIR}/result.json" >/dev/null 2>&1
assert "result.json pass-with-critical>0 rejects" "$?" "1"

rm -rf "$R_DIR"
echo ""

# --- Section 19: state.json + tests.json validators (positive + negative) ---
echo "Section 19: state.json and tests.json validators"
S_DIR=$(mktemp -d)

# state.json: positive
cat > "${S_DIR}/state.json" << 'JSON'
{
  "spec_path": ".forge/spec.md",
  "current_cycle": "C1",
  "phase": "green",
  "cycles": {
    "C1": { "status": "in_progress", "goal_condition": "x" },
    "C2": { "status": "pending",     "goal_condition": "y" }
  }
}
JSON
bash "${SCRIPTS}/cycle-validate.sh" "${S_DIR}/state.json" >/dev/null 2>&1
assert "good state.json validates"             "$?" "0"

# state.json: bad phase enum
cat > "${S_DIR}/state.json" << 'JSON'
{ "phase": "GREEN", "cycles": {} }
JSON
bash "${SCRIPTS}/cycle-validate.sh" "${S_DIR}/state.json" >/dev/null 2>&1
assert "state.json with bad phase enum rejects" "$?" "1"

# state.json: bad cycle status enum
cat > "${S_DIR}/state.json" << 'JSON'
{ "phase": "green", "cycles": { "C1": { "status": "DONE" } } }
JSON
bash "${SCRIPTS}/cycle-validate.sh" "${S_DIR}/state.json" >/dev/null 2>&1
assert "state.json with bad cycle status rejects" "$?" "1"

# tests.json: empty array now rejects (cycle-init's `[]` stub isn't a complete tests.json)
echo "[]" > "${S_DIR}/tests.json"
bash "${SCRIPTS}/cycle-validate.sh" "${S_DIR}/tests.json" >/dev/null 2>&1
assert "empty tests.json rejects"              "$?" "1"

rm -rf "$S_DIR"
echo ""

# --- Section 20: agent-config.md schema strictness ---
echo "Section 20: agent-config.md key-presence schema"
AC_DIR=$(mktemp -d)

# frontmatter present, but missing required top-level keys → reject
cat > "${AC_DIR}/agent-config.md" << 'EOF'
---
random_key: foo
---

# something
EOF
bash "${SCRIPTS}/cycle-validate.sh" "${AC_DIR}/agent-config.md" >/dev/null 2>&1
assert "agent-config without required keys rejects" "$?" "1"

rm -rf "$AC_DIR"
echo ""

# --- Section 21: spec.md required sections ---
echo "Section 21: spec.md required sections (exact match, fence-aware)"
SP_DIR=$(mktemp -d)

# Missing only ## Cycle Plan → reject
cat > "${SP_DIR}/spec.md" << 'EOF'
# Spec

## Vision
x

## Acceptance Criteria
- AC-001

## Architecture
y

## E2E Tests
- E-001

## Reviewer Config
model: opus
dimensions: [correctness]
EOF
bash "${SCRIPTS}/cycle-validate.sh" "${SP_DIR}/spec.md" >/dev/null 2>&1
assert "spec missing ONLY Cycle Plan rejects"  "$?" "1"

# Missing only ## Reviewer Config → reject
cat > "${SP_DIR}/spec.md" << 'EOF'
# Spec

## Vision
x

## Acceptance Criteria
- AC-001

## Architecture
y

## E2E Tests
- E-001

## Cycle Plan
- id: C1
EOF
bash "${SCRIPTS}/cycle-validate.sh" "${SP_DIR}/spec.md" >/dev/null 2>&1
assert "spec missing ONLY Reviewer Config rejects" "$?" "1"

# Missing only ## Acceptance Criteria → reject (newly required)
cat > "${SP_DIR}/spec.md" << 'EOF'
# Spec

## Vision
x

## Architecture
y

## E2E Tests
- E-001

## Cycle Plan
- id: C1

## Reviewer Config
model: opus
dimensions: [correctness]
EOF
bash "${SCRIPTS}/cycle-validate.sh" "${SP_DIR}/spec.md" >/dev/null 2>&1
assert "spec missing ONLY Acceptance Criteria rejects" "$?" "1"

# Heading inside fenced code block should NOT satisfy the requirement
cat > "${SP_DIR}/spec.md" << 'EOF'
# Spec

## Vision
x

## Acceptance Criteria
- AC-001

## Architecture
y

## E2E Tests
- E-001

```yaml
## Cycle Plan
- id: C1
```

## Reviewer Config
model: opus
dimensions: [correctness]
EOF
bash "${SCRIPTS}/cycle-validate.sh" "${SP_DIR}/spec.md" >/dev/null 2>&1
assert "fenced ## Cycle Plan doesn't satisfy section requirement" "$?" "1"

# Prefix-match should NOT satisfy: '## Reviewer Configuration' != '## Reviewer Config'
cat > "${SP_DIR}/spec.md" << 'EOF'
# Spec

## Vision
x

## Acceptance Criteria
- AC-001

## Architecture
y

## E2E Tests
- E-001

## Cycle Plan
- id: C1

## Reviewer Configuration
model: opus
dimensions: [correctness]
EOF
bash "${SCRIPTS}/cycle-validate.sh" "${SP_DIR}/spec.md" >/dev/null 2>&1
assert "## Reviewer Configuration doesn't satisfy ## Reviewer Config" "$?" "1"

rm -rf "$SP_DIR"
echo ""

# --- Section 22: forge-status reads Option D cycles[].status schema ---
echo "Section 22: forge-status.sh renders Option D status counts"
FS_DIR=$(mktemp -d)
cat > "${FS_DIR}/state.json" << 'JSON'
{
  "spec_path": ".forge/spec.md",
  "current_cycle": "C2",
  "phase": "green",
  "cycles": {
    "C1": { "status": "pass" },
    "C2": { "status": "in_progress" },
    "C3": { "status": "pending" }
  }
}
JSON
OUT=$(bash "${SCRIPTS}/forge-status.sh" "${FS_DIR}" 2>/dev/null || true)
echo "$OUT" | grep -q "pass=1"
assert "forge-status renders pass=1"           "$?" "0"
echo "$OUT" | grep -q "in_progress=1"
assert "forge-status renders in_progress=1"    "$?" "0"
echo "$OUT" | grep -q "pending=1"
assert "forge-status renders pending=1"        "$?" "0"
rm -rf "$FS_DIR"
echo ""

# --- Section 23: forge.sh refuses stale state.json without --resume ---
echo "Section 23: forge.sh --resume guard for stale .forge/state.json"
ST_DIR=$(mktemp -d)
mkdir -p "${ST_DIR}/.forge"
cat > "${ST_DIR}/.forge/state.json" << 'JSON'
{ "spec_path": ".forge/spec.md", "cycles": {} }
JSON

# Without --resume, stale state.json triggers an error (exit 2)
(cd "$ST_DIR" && bash "${SCRIPTS}/forge.sh" "task" --quick) >/dev/null 2>&1
assert "forge.sh refuses stale state.json"     "$?" "2"

rm -rf "$ST_DIR"
echo ""

# --- Section 24: forge.sh --help and missing-argument behavior ---
echo "Section 24: forge.sh argument handling"
HELP_OUT=$(bash "${SCRIPTS}/forge.sh" --help 2>&1)
echo "$HELP_OUT" | grep -q "Usage:"
assert "forge.sh --help emits Usage"            "$?" "0"

# Empty description → error exit 2
bash "${SCRIPTS}/forge.sh" --quick >/dev/null 2>&1
assert "forge.sh with no description exits 2"   "$?" "2"
echo ""

# --- Section 25: forge-status.sh surfaces malformed result.json ---
echo "Section 25: forge-status.sh result.json malformed detection"
MD_DIR=$(mktemp -d)
mkdir -p "${MD_DIR}/cycles/C1"
cat > "${MD_DIR}/state.json" << 'JSON'
{ "cycles": { "C1": { "status": "pass" } } }
JSON
# A malformed result.json (review_clusters shape wrong) — forge-status reads it
# via the // 0 fallback and would silently render critical=0. We don't expect
# forge-status to "validate" inline, but it should at least surface SOMETHING
# the operator can investigate. Cheapest check: the script doesn't crash.
cat > "${MD_DIR}/cycles/C1/result.json" << 'JSON'
{ "cycle_id": "C1", "status": "?", "review_clusters": "not-an-object" }
JSON
OUT=$(bash "${SCRIPTS}/forge-status.sh" "${MD_DIR}" 2>/dev/null || true)
# The script should still emit its header even with malformed cycle data.
echo "$OUT" | grep -q "Forge Status"
assert "forge-status survives malformed result.json" "$?" "0"
rm -rf "$MD_DIR"
echo ""

# --- Summary ---
echo "=== Smoke summary ==="
echo "  Passed:  $PASSED"
echo "  Failed:  $FAILED"
echo "  Skipped: $SKIPPED"
if [[ "$FAILED" != "0" ]]; then
  echo ""
  echo "Failed assertions:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
