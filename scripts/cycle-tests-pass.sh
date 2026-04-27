#!/usr/bin/env bash
# Wrapper around the project's test command. Surfaces exit code and parsed
# pass/fail counts to red.log or green.log.
#
# Usage: cycle-tests-pass.sh <phase> <cycle-dir> -- <test-command...>
#   <phase>      red | green
#   <cycle-dir>  e.g. .forge/cycles/1
#   <test-cmd>   the project's test command (e.g. pnpm test, sui move test)
#
# Behavior:
#   - Runs the test command
#   - Captures the underlying test command's exit code
#   - Writes the combined output to <cycle-dir>/<phase>.log
#   - Writes <cycle-dir>/<phase>.json with phase, exit_code, started_at,
#     ended_at, command, and phase_pass (whether the phase succeeded)
#
# Exit-code semantics — INVERSION FOR RED:
#   This script answers "did the phase succeed?" not "did the test command pass?"
#   - red:   phase succeeds when tests FAIL (test runner exits non-zero).
#            Script exits 0 when test command exited non-zero.
#            Script exits 1 when test command exited 0 (tautological tests — bad).
#   - green: phase succeeds when tests PASS (test runner exits zero).
#            Script exits 0 when test command exited 0.
#            Script exits 1 when test command exited non-zero (impl incomplete).
#
# This is forge-guard rule 2 (§8) implemented at the script level rather than
# the hook level — the script IS the gate.

set -u
set -o pipefail

PHASE="${1:-}"
CYCLE_DIR="${2:-}"
SEP="${3:-}"

if [[ "$PHASE" != "red" && "$PHASE" != "green" ]] || [[ -z "$CYCLE_DIR" ]] || [[ "$SEP" != "--" ]]; then
  echo "Usage: cycle-tests-pass.sh <red|green> <cycle-dir> -- <test-cmd...>" >&2
  exit 2
fi

shift 3
if [[ $# -eq 0 ]]; then
  echo "ERROR: no test command supplied after --" >&2
  exit 2
fi

mkdir -p "$CYCLE_DIR"
LOG="$CYCLE_DIR/$PHASE.log"
META="$CYCLE_DIR/$PHASE.json"

START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TEST_EXIT=0
"$@" >"$LOG" 2>&1 || TEST_EXIT=$?
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Phase-pass logic: invert for red.
PHASE_PASS=false
PHASE_EXIT=1
if [[ "$PHASE" == "red" ]]; then
  if [[ "$TEST_EXIT" -ne 0 ]]; then
    PHASE_PASS=true
    PHASE_EXIT=0
  fi
else
  # green
  if [[ "$TEST_EXIT" -eq 0 ]]; then
    PHASE_PASS=true
    PHASE_EXIT=0
  fi
fi

cat > "$META" << JSON
{
  "phase": "$PHASE",
  "exit_code": $TEST_EXIT,
  "phase_pass": $PHASE_PASS,
  "started_at": "$START",
  "ended_at": "$END",
  "command": "$(printf '%s ' "$@" | sed 's/"/\\"/g' | sed 's/ $//')"
}
JSON

echo "[$PHASE] command:    $*"
echo "[$PHASE] test exit:  $TEST_EXIT"
echo "[$PHASE] phase_pass: $PHASE_PASS"
echo "[$PHASE] log:        $LOG"
echo "[$PHASE] meta:       $META"

if [[ "$PHASE" == "red" ]] && [[ "$PHASE_PASS" == "false" ]]; then
  echo ""
  echo "FAIL: red phase requires tests to fail (got exit code 0)."
  echo "  This is the tautological-test detector. The tests passed at red,"
  echo "  meaning they don't actually exercise the behavior under test."
  echo "  Rewrite tests so they fail with the expected failure mode before"
  echo "  proceeding to green."
fi

if [[ "$PHASE" == "green" ]] && [[ "$PHASE_PASS" == "false" ]]; then
  echo ""
  echo "FAIL: green phase requires tests to pass (got exit code $TEST_EXIT)."
  echo "  See $LOG for the failure output."
fi

exit "$PHASE_EXIT"
