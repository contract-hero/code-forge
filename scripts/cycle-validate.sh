#!/usr/bin/env bash
# Strict schema validator for forge cycle artifacts.
#
# Usage: cycle-validate.sh <path>
#   <path> can be:
#     - a cycle directory (e.g. .forge/cycles/1/) — validates everything found
#     - a reviewers directory (e.g. .forge/cycles/1/reviewers/) — validates subagent-*.json
#     - a single .json file (subagent-N.json or tests.json) — validates that file
#
# Validates whatever it finds:
#   - subagent-N.json (N in 0..REVIEWERS) — reviewer findings, strict schema
#   - tests.json — test list (test-author phase)
#   - contract.md — structural check (required H2 sections)
#
# Exits non-zero if any artifact fails validation.
#
# Env:
#   REVIEWERS — max reviewer index (default 6)
#
# Requires: jq.

set -u
set -o pipefail

REVIEWERS="${REVIEWERS:-6}"
TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
  echo "Usage: cycle-validate.sh <path>" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found in PATH" >&2
  exit 2
fi

VALID_SEVERITIES='["critical","high","medium","low","info"]'
VALID_CONFIDENCE='["high","medium","low"]'
VALID_CATEGORIES='["correctness","design","error-handling","simplicity","tests-vs-impl","dependencies","security","performance","documentation","build"]'
VALID_TEST_KINDS='["unit","integration","property"]'

OVERALL=0

validate_reviewer() {
  local f="$1"
  local n
  n=$(basename "$f" | sed -n 's/^subagent-\([0-9]\+\)\.json$/\1/p')
  if [[ -z "$n" ]]; then
    echo "  SKIP: $f does not match subagent-N.json"
    return 0
  fi

  echo "=== validating $(basename "$f") (reviewer $n) ==="

  if ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    echo "  FAIL: not a JSON array" >&2
    OVERALL=1
    return 1
  fi

  local bad
  bad=$(jq --argjson sevs "$VALID_SEVERITIES" \
           --argjson confs "$VALID_CONFIDENCE" \
           --argjson cats "$VALID_CATEGORIES" \
           --arg ridprefix "R$n-" '
    [ .[] | select(
        (has("id") | not) or (.id | tostring | startswith($ridprefix) | not) or
        (has("title") | not) or (.title | type != "string") or (.title == "") or
        (has("severity") | not) or (.severity as $s | $sevs | index($s) == null) or
        (has("category") | not) or (.category as $c | $cats | index($c) == null) or
        (has("file") | not) or (.file | type != "string") or (.file == "") or
        (has("line_range") | not) or (.line_range | type != "string") or (.line_range == "") or
        (has("description") | not) or (.description | type != "string") or (.description == "") or
        (has("impact") | not) or (.impact | type != "string") or (.impact == "") or
        (has("recommendation") | not) or (.recommendation | type != "string") or (.recommendation == "") or
        (has("evidence") | not) or (.evidence | type != "string") or (.evidence == "") or
        (has("confidence") | not) or (.confidence as $c | $confs | index($c) == null)
      ) | .id // "<missing-id>"
    ]' "$f")

  local bad_count total
  bad_count=$(echo "$bad" | jq 'length')
  total=$(jq 'length' "$f")
  if [[ "$bad_count" != "0" ]]; then
    echo "  FAIL: $bad_count of $total entries failed schema check"
    echo "  Failing IDs: $bad"
    OVERALL=1
  else
    echo "  OK ($total findings)"
  fi
}

validate_tests_json() {
  local f="$1"
  echo "=== validating tests.json ==="

  if ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    echo "  FAIL: not a JSON array" >&2
    OVERALL=1
    return 1
  fi

  local bad
  bad=$(jq --argjson kinds "$VALID_TEST_KINDS" '
    [ .[] | select(
        (has("id") | not) or (.id | tostring | test("^T-[0-9]{3}$") | not) or
        (has("name") | not) or (.name | type != "string") or (.name == "") or
        (has("behavior") | not) or (.behavior | type != "string") or (.behavior == "") or
        (has("kind") | not) or (.kind as $k | $kinds | index($k) == null) or
        (has("target_file") | not) or (.target_file | type != "string") or (.target_file == "")
      ) | .id // "<missing-id>"
    ]' "$f")

  local bad_count total
  bad_count=$(echo "$bad" | jq 'length')
  total=$(jq 'length' "$f")
  if [[ "$bad_count" != "0" ]]; then
    echo "  FAIL: $bad_count of $total tests failed schema check"
    echo "  Failing IDs: $bad"
    OVERALL=1
  else
    echo "  OK ($total tests)"
  fi
}

validate_contract_md() {
  local f="$1"
  echo "=== validating contract.md ==="

  local missing=0
  if ! grep -q '^# ' "$f"; then
    echo "  FAIL: missing H1 title"
    missing=1
  fi
  for section in "## Behavior" "## Files" "## Acceptance"; do
    if ! grep -q "^${section}" "$f"; then
      echo "  FAIL: missing required section '${section}'"
      missing=1
    fi
  done

  if [[ "$missing" == "0" ]]; then
    echo "  OK"
  else
    OVERALL=1
  fi
}

# Dispatch on target type
if [[ -f "$TARGET" ]]; then
  case "$(basename "$TARGET")" in
    subagent-*.json) validate_reviewer "$TARGET" ;;
    tests.json) validate_tests_json "$TARGET" ;;
    contract.md) validate_contract_md "$TARGET" ;;
    *) echo "ERROR: don't know how to validate $TARGET" >&2; exit 2 ;;
  esac
elif [[ -d "$TARGET" ]]; then
  # Find and validate every recognized artifact in the directory tree
  found_any=0
  while IFS= read -r f; do
    found_any=1
    case "$(basename "$f")" in
      subagent-*.json) validate_reviewer "$f" ;;
      tests.json) validate_tests_json "$f" ;;
      contract.md) validate_contract_md "$f" ;;
    esac
  done < <(find "$TARGET" \( -name 'subagent-*.json' -o -name 'tests.json' -o -name 'contract.md' \) -type f 2>/dev/null)

  if [[ "$found_any" == "0" ]]; then
    echo "WARN: no recognized artifacts found in $TARGET"
  fi
else
  echo "ERROR: $TARGET is neither a file nor a directory" >&2
  exit 2
fi

exit "$OVERALL"
