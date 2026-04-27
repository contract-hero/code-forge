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

# Stand up a temp dir with a green-phase .forge/ scaffolding for hook tests.
# F11 made the hook itself realpath-aware, so we no longer need to canonicalize
# the temp dir up-front. Returning the raw mktemp path lets the F11 assertion
# exercise the symlink-crossing case for real.
# Args: $1 test_file path; $2 optional target_file (default src/foo.ts).
# Echoes the temp dir path; caller is responsible for `rm -rf` cleanup.
setup_green_phase_fixture() {
  local test_file="$1"
  local target_file="${2:-src/foo.ts}"
  local dir
  dir=$(mktemp -d)
  mkdir -p "${dir}/.forge/cycles/1"
  cat > "${dir}/.forge/state.json" << 'JSON'
{ "phase": "green", "current_cycle": 1, "iteration": 0 }
JSON
  printf '[{"id":"T-001","name":"x","behavior":"x","kind":"unit","target_file":"%s","test_file":"%s"}]\n' \
    "$target_file" "$test_file" > "${dir}/.forge/cycles/1/tests.json"
  echo "$dir"
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

# --- F2: sed portability — reviewer-index extraction round-trip ---
# Regression guard for the GNU-vs-BSD sed-ism on macOS. cycle-validate.sh
# extracts a reviewer number from "subagent-N.json" basenames; before F2 it
# used \+ which BSD sed silently no-ops, leaving N empty and skipping the
# per-reviewer ID prefix check. This assertion proves the extractor returns
# a non-empty digit string on the canonical fixture.
echo "Section 1.5: sed portability"
n=$(basename "${FIXTURES}/cycle-good/reviewers/subagent-3.json" \
    | sed -n 's/^subagent-\([0-9][0-9]*\)\.json$/\1/p')
[[ "$n" == "3" ]]
assert "F2: reviewer-index extraction is non-empty on macOS" "$?" "0"
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

# --- pre-cycle artifact validators (P2/P4 / v0.2.0) ---
echo "Section 7.5: pre-cycle validators"
PC_DIR=$(mktemp -d)

# Empty plan.md → reject
: > "${PC_DIR}/plan.md"
bash "${SCRIPTS}/cycle-validate.sh" "${PC_DIR}/plan.md" >/dev/null 2>&1
assert "empty plan.md rejects"               "$?" "1"

# Non-empty plan.md → accept
echo -e "# Plan\n\nDoes things." > "${PC_DIR}/plan.md"
bash "${SCRIPTS}/cycle-validate.sh" "${PC_DIR}/plan.md" >/dev/null 2>&1
assert "non-empty plan.md validates"         "$?" "0"

# Spec without ## E2E Tests → reject
cat > "${PC_DIR}/spec.md" << 'SPECMD'
# Project Spec

## Vision
Do things.

## Core Features
- A thing.

## Architecture Overview
Use code.
SPECMD
bash "${SCRIPTS}/cycle-validate.sh" "${PC_DIR}/spec.md" >/dev/null 2>&1
assert "spec without E2E Tests rejects"      "$?" "1"

# Spec with ## E2E Tests → accept
echo -e "\n## E2E Tests\n- E-001: thing happens" >> "${PC_DIR}/spec.md"
bash "${SCRIPTS}/cycle-validate.sh" "${PC_DIR}/spec.md" >/dev/null 2>&1
assert "spec with E2E Tests validates"       "$?" "0"

# cycle-plan.md without any '## Cycle' heading → reject
echo "# Cycle Plan" > "${PC_DIR}/cycle-plan.md"
bash "${SCRIPTS}/cycle-validate.sh" "${PC_DIR}/cycle-plan.md" >/dev/null 2>&1
assert "cycle-plan without Cycle heading rejects" "$?" "1"

# cycle-plan.md with cycles → accept
echo -e "\n## Cycle 1 — bootstrap\n- Goal: do something" >> "${PC_DIR}/cycle-plan.md"
bash "${SCRIPTS}/cycle-validate.sh" "${PC_DIR}/cycle-plan.md" >/dev/null 2>&1
assert "cycle-plan with Cycle heading validates"  "$?" "0"

rm -rf "${PC_DIR}"
echo ""

# --- agent-config.md schema (P3 / v0.2.0) ---
echo "Section 8: agent-config.md schema"
bash "${SCRIPTS}/cycle-validate.sh" "${FIXTURES}/cycle-good/agent-config.md" >/dev/null 2>&1
assert "greenfield agent-config validates"   "$?" "0"

bash "${SCRIPTS}/cycle-validate.sh" "${FIXTURES}/cycle-good-sui/agent-config.md" >/dev/null 2>&1
assert "sui agent-config validates"          "$?" "0"

# Missing frontmatter rejection — file basename must be exactly agent-config.md
BAD_AC_DIR=$(mktemp -d)
echo "no frontmatter here" > "${BAD_AC_DIR}/agent-config.md"
bash "${SCRIPTS}/cycle-validate.sh" "${BAD_AC_DIR}/agent-config.md" >/dev/null 2>&1
assert "missing-frontmatter agent-config rejects" "$?" "1"
rm -rf "$BAD_AC_DIR"
echo ""

# --- best-of-N fixture (P5 / v0.2.0) ---
echo "Section 8.5: best-of-N fixture"
BON="${FIXTURES}/cycle-good-with-best-of-n"

# Cycle artifacts validate (contract.md, tests.json)
bash "${SCRIPTS}/cycle-validate.sh" "${BON}/contract.md" >/dev/null 2>&1
assert "best-of-N contract.md validates"     "$?" "0"
bash "${SCRIPTS}/cycle-validate.sh" "${BON}/tests.json" >/dev/null 2>&1
assert "best-of-N tests.json validates"      "$?" "0"

# All six worker manifests exist
worker_count=$(find "${BON}/green/candidates" -mindepth 1 -maxdepth 1 -type d -name 'worker-*' | wc -l | tr -d ' ')
[[ "$worker_count" == "6" ]]
assert "best-of-N has 6 worker dirs"         "$?" "0"

manifest_count=$(find "${BON}/green/candidates" -name manifest.json | wc -l | tr -d ' ')
[[ "$manifest_count" == "6" ]]
assert "best-of-N has 6 manifests"           "$?" "0"

# Synthesis notes mention the chosen worker
grep -q '^worker-4' "${BON}/green/synthesis-notes.md"
assert "synthesis-notes names a winner"      "$?" "0"

# Coordinator pick metric: chosen worker's manifest claims tests_pass=true
chosen_pass=$(jq -r '.tests_pass' "${BON}/green/candidates/worker-4/manifest.json")
[[ "$chosen_pass" == "true" ]]
assert "chosen worker passes tests"          "$?" "0"

# Coordinator pick metric: chosen worker has the lowest LOC among passers
chosen_loc=$(jq -r '.lines_changed' "${BON}/green/candidates/worker-4/manifest.json")
min_loc=$(for K in 1 3 4 5; do jq -r '.lines_changed' "${BON}/green/candidates/worker-${K}/manifest.json"; done | sort -n | head -1)
[[ "$chosen_loc" == "$min_loc" ]]
assert "chosen worker has min LOC of passers" "$?" "0"
echo ""

# --- forge-guard rule 6: specialist routing (P3 / v0.2.0) ---
echo "Section 9: forge-guard rule 6 (specialist routing)"
HOOK="${PLUGIN_ROOT}/hooks/forge-guard.mjs"
GUARD_TEST_DIR=$(mktemp -d)
mkdir -p "${GUARD_TEST_DIR}/.forge"
cp "${FIXTURES}/cycle-good-sui/agent-config.md" "${GUARD_TEST_DIR}/.forge/agent-config.md"

# F7 (v0.3.x): project_domains forces sui-pilot only for source-touching roles.
# Orchestration roles (planner, test-author, implementer-coordinator, consolidator,
# codebase-explorer) keep their own tool surfaces — sui-pilot lacks Codex MCP /
# Agent / etc. that those roles depend on.

# Source-touching role mismatched → BLOCK
echo '{"tool_name":"Task","tool_input":{"subagent_type":"code-forge-v2:forge-implementer-worker","prompt":"impl-worker on src/foo.move","description":"x"}}' \
  | (cd "${GUARD_TEST_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
# subagent_type doesn't match sui-pilot → blocks (because role IS implementer-worker, IS forced)
# But wait — subagent_type IS code-forge-v2:forge-implementer-worker, not sui-pilot.
# That's the violation. Expect exit 2.
assert "F7: implementer-worker without sui-pilot blocks" "$?" "2"

# Source-touching role with sui-pilot → ALLOW
echo '{"tool_name":"Task","tool_input":{"subagent_type":"sui-pilot:sui-pilot-agent","prompt":"as implementer-worker, edit src/foo.move","description":"x"}}' \
  | (cd "${GUARD_TEST_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "F7: implementer-worker with sui-pilot allows" "$?" "0"

# Reviewer dispatch without sui-pilot → BLOCK
echo '{"tool_name":"Task","tool_input":{"subagent_type":"code-forge-v2:forge-reviewer","prompt":"REVIEWER_DIMENSION=correctness; review src/foo.move","description":"reviewer"}}' \
  | (cd "${GUARD_TEST_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
# reviewer mismatch → BLOCK by F7. (rule 3 also fires? No — no prior subagent-N.json files yet.)
assert "F7: reviewer without sui-pilot blocks" "$?" "2"

# F7 critical: orchestration roles ALLOWED through project_domains rule.
# These need their own tool surfaces (Codex MCP, Agent), so sui-pilot would break them.
# planner dispatch (orchestration) under project_domains: [sui-dapp] → ALLOW
echo '{"tool_name":"Task","tool_input":{"subagent_type":"code-forge-v2:forge-planner","prompt":"draft contract.md for cycle 1","description":"planner contract"}}' \
  | (cd "${GUARD_TEST_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "F7: planner orchestration role allowed under sui-dapp" "$?" "0"

# implementer-coordinator dispatch (orchestration) under project_domains: [sui-dapp] → ALLOW
echo '{"tool_name":"Task","tool_input":{"subagent_type":"code-forge-v2:forge-implementer","prompt":"green-phase coordinator: dispatch 6 workers","description":"implementer coord"}}' \
  | (cd "${GUARD_TEST_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "F7: implementer coordinator allowed under sui-dapp" "$?" "0"

# consolidator dispatch (orchestration) → ALLOW (matches F5 + F7 logic)
echo '{"tool_name":"Task","tool_input":{"subagent_type":"code-forge-v2:forge-consolidator","prompt":"synthesize subagent-N.json into review.md","description":"consolidator"}}' \
  | (cd "${GUARD_TEST_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "F7: consolidator allowed under sui-dapp" "$?" "0"

# Greenfield agent-config (empty project_domains, empty required) + arbitrary subagent → ALLOW
cp "${FIXTURES}/cycle-good/agent-config.md" "${GUARD_TEST_DIR}/.forge/agent-config.md"
echo '{"tool_name":"Task","tool_input":{"subagent_type":"general-purpose","prompt":"do work","description":"x"}}' \
  | (cd "${GUARD_TEST_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "greenfield routing skips"            "$?" "0"

# F12 (v0.4.x): required_subagents glob fallback now matches against the in-scope
# files listed in cycles/N/contract.md, not prompt-text path tokens. Set up a
# minimal state.json + contract.md so the rule has something to read.
cat > "${GUARD_TEST_DIR}/.forge/agent-config.md" << 'EOF'
---
project_domains: []
required_subagents:
  - match: "**/*.move"
    subagent_type: "sui-pilot:sui-pilot-agent"
    applies_to: [planner, implementer-worker, reviewer]
recommended_agents: []
---
EOF
mkdir -p "${GUARD_TEST_DIR}/.forge/cycles/1"
cat > "${GUARD_TEST_DIR}/.forge/state.json" << 'JSON'
{ "phase": "contract", "current_cycle": 1, "iteration": 0 }
JSON
cat > "${GUARD_TEST_DIR}/.forge/cycles/1/contract.md" << 'EOF'
# Cycle 1 — sui contract

## Behavior
Add a Move module that does X.

## Files
- src/foo.move
- src/index.ts

## Acceptance
- foo.move compiles.
EOF

# F12: contract lists a .move file → glob match → impl-worker without sui-pilot BLOCKS
echo '{"tool_name":"Task","tool_input":{"subagent_type":"code-forge-v2:forge-implementer-worker","prompt":"impl-worker","description":"x"}}' \
  | (cd "${GUARD_TEST_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "F12: glob fallback blocks via contract.md" "$?" "2"

# F12: same glob, but applies_to scope excludes consolidator → ALLOW
echo '{"tool_name":"Task","tool_input":{"subagent_type":"code-forge-v2:forge-consolidator","prompt":"consolidator","description":"x"}}' \
  | (cd "${GUARD_TEST_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "F12: applies_to scope respected" "$?" "0"

# F12: pre-cycle dispatch (current_cycle=0, no contract.md to read) → SKIP rule, ALLOW
cat > "${GUARD_TEST_DIR}/.forge/state.json" << 'JSON'
{ "phase": "spec-and-e2e", "current_cycle": 0, "iteration": 0 }
JSON
echo '{"tool_name":"Task","tool_input":{"subagent_type":"code-forge-v2:forge-planner","prompt":"draft spec.md","description":"planner"}}' \
  | (cd "${GUARD_TEST_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "F12: pre-cycle dispatch skips rule"  "$?" "0"

# F12: contract has no matching files → ALLOW (no .move in this contract)
cat > "${GUARD_TEST_DIR}/.forge/state.json" << 'JSON'
{ "phase": "contract", "current_cycle": 1, "iteration": 0 }
JSON
cat > "${GUARD_TEST_DIR}/.forge/cycles/1/contract.md" << 'EOF'
# Cycle 1 — pure TS contract

## Behavior
Add a TypeScript helper.

## Files
- src/foo.ts
- tests/foo.test.ts

## Acceptance
- helper does Y.
EOF
echo '{"tool_name":"Task","tool_input":{"subagent_type":"general-purpose","prompt":"impl-worker","description":"x"}}' \
  | (cd "${GUARD_TEST_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "F12: contract with no matching file allows" "$?" "0"

rm -rf "$GUARD_TEST_DIR"
echo ""

# --- forge-guard rule 7: implementer-worker fan-out (P5 / v0.2.0) ---
echo "Section 10: forge-guard rule 7 (worker fan-out)"
W7="$(mktemp -d)"
mkdir -p "${W7}/.forge/cycles/1/green/candidates/worker-1"
cat > "${W7}/.forge/state.json" << 'JSON'
{ "phase": "green", "current_cycle": 1, "iteration": 0 }
JSON

# Worker-1 candidate dir already exists with old mtime — second worker dispatch should block
touch -t 200001010000 "${W7}/.forge/cycles/1/green/candidates/worker-1"
echo '{"tool_name":"Task","tool_input":{"subagent_type":"code-forge-v2:forge-implementer-worker","prompt":"stage your candidate at green/candidates/worker-2","description":"impl worker"}}' \
  | (cd "${W7}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "rule 7 blocks serial worker dispatch" "$?" "2"

# Fresh candidate dir (just created) — should NOT block
W7B="$(mktemp -d)"
mkdir -p "${W7B}/.forge/cycles/1/green/candidates/worker-1"
cat > "${W7B}/.forge/state.json" << 'JSON'
{ "phase": "green", "current_cycle": 1, "iteration": 0 }
JSON
echo '{"tool_name":"Task","tool_input":{"subagent_type":"code-forge-v2:forge-implementer-worker","prompt":"stage your candidate at green/candidates/worker-2","description":"impl worker"}}' \
  | (cd "${W7B}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "rule 7 allows in-turn worker dispatch" "$?" "0"

# Not in green phase — rule 7 should not apply even with old worker dir
W7C="$(mktemp -d)"
mkdir -p "${W7C}/.forge/cycles/1/green/candidates/worker-1"
touch -t 200001010000 "${W7C}/.forge/cycles/1/green/candidates/worker-1"
cat > "${W7C}/.forge/state.json" << 'JSON'
{ "phase": "test-list", "current_cycle": 1, "iteration": 0 }
JSON
echo '{"tool_name":"Task","tool_input":{"subagent_type":"code-forge-v2:forge-implementer-worker","prompt":"hi","description":"impl worker"}}' \
  | (cd "${W7C}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "rule 7 skips outside green phase"     "$?" "0"

rm -rf "$W7" "$W7B" "$W7C"
echo ""

# --- F4: worker candidate-prefix peel for test-file blocking ---
echo "Section 10.5: F4 — candidate-staging prefix peel"
F4_DIR=$(setup_green_phase_fixture "test/strip-ansi.test.ts" "src/strip-ansi.ts")
mkdir -p "${F4_DIR}/.forge/cycles/1/green/candidates/worker-3/files"

# Worker writing to a test_file path INSIDE its candidate dir → BLOCK
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${F4_DIR}/.forge/cycles/1/green/candidates/worker-3/files/test/strip-ansi.test.ts\"}}" \
  | (cd "${F4_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "F4: hook blocks worker test-file edit"  "$?" "2"

# Worker writing to a target_file source path inside its candidate dir → ALLOW
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${F4_DIR}/.forge/cycles/1/green/candidates/worker-3/files/src/strip-ansi.ts\"}}" \
  | (cd "${F4_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "F4: hook allows worker source edit"     "$?" "0"

rm -rf "$F4_DIR"
echo ""

# --- target_file/test_file schema split (F1 / v0.3.x) ---
echo "Section 11.5: F1 — test_file hook block"
F1_DIR=$(setup_green_phase_fixture "tests/foo.test.ts")

# Hook BLOCKS Edit on a test_file path during green
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${F1_DIR}/tests/foo.test.ts\"}}" \
  | (cd "${F1_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "F1: hook blocks edit on test_file"   "$?" "2"

# Hook ALLOWS Edit on a target_file source path during green (anti-weakening only blocks tests)
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${F1_DIR}/src/foo.ts\"}}" \
  | (cd "${F1_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
assert "F1: hook allows edit on target_file" "$?" "0"

# Schema validation rejects tests.json missing test_file
printf '[{"id":"T-001","name":"x","behavior":"x","kind":"unit","target_file":"src/foo.ts"}]\n' \
  > "${F1_DIR}/.forge/cycles/1/tests.json"
bash "${SCRIPTS}/cycle-validate.sh" "${F1_DIR}/.forge/cycles/1/tests.json" >/dev/null 2>&1
assert "F1: tests.json without test_file rejects" "$?" "1"

rm -rf "$F1_DIR"
echo ""

# --- F11: realpath in makeRepoRelative (macOS /var → /private/var) ---
# setup_green_phase_fixture now returns the raw mktemp path. On macOS that's
# typically /var/folders/... whose canonical form is /private/var/folders/...
# Pre-F11, the hook's string-prefix compare missed the match because cwd
# resolved the symlink but file_path didn't. Post-F11, makeRepoRelative
# realpaths both sides — this assertion proves the block fires correctly even
# with a symlink-crossing path.
echo "Section 11.6: F11 — realpath path normalization"
F11_DIR=$(setup_green_phase_fixture "tests/foo.test.ts")
# Sanity: confirm we're actually exercising the symlink case on macOS.
F11_REAL=$(cd "$F11_DIR" && pwd -P)
if [[ "$F11_DIR" == "$F11_REAL" ]]; then
  echo "  SKIP: F11 case (no symlink in temp-dir path; nothing to exercise here)"
else
  echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${F11_DIR}/tests/foo.test.ts\"}}" \
    | (cd "${F11_DIR}" && node "${HOOK}" pre-tool-use) >/dev/null 2>&1
  assert "F11: hook blocks across /var symlink"  "$?" "2"
fi
rm -rf "$F11_DIR"
echo ""

# --- e2e-extract.sh + cycle-e2e-pass.sh + scenarios.json schema (P6 / v0.2.0) ---
echo "Section 11: Phase F (e2e)"

# e2e-extract.sh roundtrip — parse spec.md ## E2E Tests, validate output
E2E_OUT=$(mktemp -d)
bash "${SCRIPTS}/e2e-extract.sh" "${FIXTURES}/e2e-spec-source/spec.md" "${E2E_OUT}/scenarios.json" >/dev/null 2>&1
assert "e2e-extract.sh runs"                 "$?" "0"
[[ -f "${E2E_OUT}/scenarios.json" ]]
assert "e2e-extract emitted scenarios.json"  "$?" "0"
extracted_count=$(jq 'length' "${E2E_OUT}/scenarios.json" 2>/dev/null || echo "?")
[[ "$extracted_count" == "2" ]]
assert "e2e-extract found 2 scenarios"       "$?" "0"
bash "${SCRIPTS}/cycle-validate.sh" "${E2E_OUT}/scenarios.json" >/dev/null 2>&1
assert "extracted scenarios.json validates"  "$?" "0"
rm -rf "$E2E_OUT"

# scenarios.json schema — fixture-based
bash "${SCRIPTS}/cycle-validate.sh" "${FIXTURES}/e2e-good/scenarios.json" >/dev/null 2>&1
assert "e2e-good scenarios.json validates"   "$?" "0"

# F3: e2e-extract round-trips a planner-shaped spec (more realistic than the
# minimal e2e-spec-source fixture — has full prose sections plus the canonical
# fenced-YAML block the planner is told to copy verbatim).
PSHAPE_OUT=$(mktemp -d)
bash "${SCRIPTS}/e2e-extract.sh" "${FIXTURES}/e2e-spec-source-planner-shape/spec.md" "${PSHAPE_OUT}/scenarios.json" >/dev/null 2>&1
assert "F3: planner-shape extracts cleanly"  "$?" "0"
bash "${SCRIPTS}/cycle-validate.sh" "${PSHAPE_OUT}/scenarios.json" >/dev/null 2>&1
assert "F3: planner-shape scenarios validate" "$?" "0"
pshape_count=$(jq 'length' "${PSHAPE_OUT}/scenarios.json" 2>/dev/null || echo "?")
[[ "$pshape_count" == "3" ]]
assert "F3: planner-shape extracted 3 scenarios" "$?" "0"
rm -rf "${PSHAPE_OUT}"

# F3 negative direction: bullets-shape ## E2E Tests must NOT silently produce
# zero scenarios — that would let a planner-output regression skip Phase F
# entirely. e2e-extract.sh exits non-zero when the section is present but
# parses to zero scenarios.
BULLETS_OUT=$(mktemp -d)
bash "${SCRIPTS}/e2e-extract.sh" "${FIXTURES}/e2e-spec-source-bullets/spec.md" "${BULLETS_OUT}/scenarios.json" >/dev/null 2>&1
assert "F3: bullets-shape rejects (extractor exit non-zero)" "$?" "1"
rm -rf "${BULLETS_OUT}"

# Malformed scenarios.json (missing required fields) → reject
BAD_SCEN=$(mktemp -d)
echo '[{"id":"E-001","name":"x"}]' > "${BAD_SCEN}/scenarios.json"
bash "${SCRIPTS}/cycle-validate.sh" "${BAD_SCEN}/scenarios.json" >/dev/null 2>&1
assert "malformed scenarios.json rejects"    "$?" "1"
rm -rf "$BAD_SCEN"

# cycle-e2e-pass.sh — passing fixture
bash "${SCRIPTS}/cycle-e2e-pass.sh" "${FIXTURES}/e2e-good" >/dev/null 2>&1
assert "e2e-good fixture passes ship gate"   "$?" "0"

# cycle-e2e-pass.sh — failing fixture (critical cluster + uncovered scenario)
bash "${SCRIPTS}/cycle-e2e-pass.sh" "${FIXTURES}/e2e-bad" >/dev/null 2>&1
assert "e2e-bad fixture fails ship gate"     "$?" "1"
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
