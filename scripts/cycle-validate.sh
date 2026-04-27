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
VALID_CATEGORIES='["correctness","design","error-handling","simplicity","tests-vs-impl","dependencies","security","performance","documentation","build","e2e-flow"]'
VALID_TEST_KINDS='["unit","integration","property"]'
VALID_E2E_KINDS='["ui","api","cli"]'
VALID_DOMAIN_RELEVANCE='["high","medium","low"]'
KNOWN_PROJECT_DOMAINS='["sui-dapp","walrus","seal","sui-cli"]'

OVERALL=0

validate_reviewer() {
  local f="$1"
  local n
  # POSIX-portable: use [0-9][0-9]* instead of \+ (GNU-only). BSD sed on macOS
  # treats \+ as literal '+', so the capture group never matches and reviewer
  # ID prefix validation silently no-ops.
  n=$(basename "$f" | sed -n 's/^subagent-\([0-9][0-9]*\)\.json$/\1/p')
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
        (has("target_file") | not) or (.target_file | type != "string") or (.target_file == "") or
        (has("test_file") | not) or (.test_file | type != "string") or (.test_file == "")
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

validate_plan_md() {
  local f="$1"
  echo "=== validating plan.md ==="
  if [[ ! -s "$f" ]]; then
    echo "  FAIL: plan.md is empty or missing"
    OVERALL=1
    return 1
  fi
  if ! grep -q '^# ' "$f"; then
    echo "  FAIL: plan.md missing H1 title"
    OVERALL=1
    return 1
  fi
  echo "  OK"
}

validate_spec_md() {
  local f="$1"
  echo "=== validating spec.md ==="
  if [[ ! -s "$f" ]]; then
    echo "  FAIL: spec.md is empty or missing"
    OVERALL=1
    return 1
  fi
  local missing=0
  if ! grep -q '^# ' "$f"; then
    echo "  FAIL: missing H1 title"
    missing=1
  fi
  # Required sections — Phase 1 output must include E2E Tests
  for section in "## Vision" "## Core Features" "## Architecture Overview" "## E2E Tests"; do
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

validate_cycle_plan_md() {
  local f="$1"
  echo "=== validating cycle-plan.md ==="
  if [[ ! -s "$f" ]]; then
    echo "  FAIL: cycle-plan.md is empty or missing"
    OVERALL=1
    return 1
  fi
  if ! grep -q '^## Cycle ' "$f"; then
    echo "  FAIL: cycle-plan.md must contain at least one '## Cycle N' heading"
    OVERALL=1
    return 1
  fi
  echo "  OK"
}

# Extract YAML frontmatter (between leading --- and closing ---) into stdout.
extract_frontmatter() {
  awk 'BEGIN{infm=0; n=0} /^---[[:space:]]*$/ { n++; if(n==1){infm=1; next} else if(n==2){infm=0; exit} } infm{print}' "$1"
}

validate_agent_config_md() {
  local f="$1"
  echo "=== validating agent-config.md ==="
  if [[ ! -s "$f" ]]; then
    echo "  FAIL: agent-config.md is empty or missing"
    OVERALL=1
    return 1
  fi

  local fm
  fm=$(extract_frontmatter "$f")
  if [[ -z "$fm" ]]; then
    echo "  FAIL: agent-config.md must start with --- YAML frontmatter ---"
    OVERALL=1
    return 1
  fi

  # Required top-level keys (presence; values may be empty arrays).
  local missing=0
  for key in "project_domains" "required_subagents" "recommended_agents"; do
    if ! echo "$fm" | grep -qE "^${key}:"; then
      echo "  FAIL: missing required frontmatter key '${key}'"
      missing=1
    fi
  done

  # If a parser is available, do a fuller schema check; else stop at presence.
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 - <<'PY' "$f" "$KNOWN_PROJECT_DOMAINS" "$VALID_DOMAIN_RELEVANCE"
import sys, re, json
path, known_domains_json, known_relevance_json = sys.argv[1], sys.argv[2], sys.argv[3]
known_domains = set(json.loads(known_domains_json))
known_relevance = set(json.loads(known_relevance_json))

with open(path) as fh:
    text = fh.read()
m = re.match(r"^---\s*\n(.*?)\n---", text, re.S)
if not m:
    print("  FAIL: cannot find YAML frontmatter delimiters", file=sys.stderr)
    sys.exit(1)
body = m.group(1)

try:
    import yaml
except ImportError:
    # PyYAML unavailable — fall back to presence-only check.
    print("  WARN: PyYAML not installed; agent-config.md schema check is presence-only")
    sys.exit(0)

try:
    data = yaml.safe_load(body) or {}
except Exception as e:
    print(f"  FAIL: YAML parse error: {e}", file=sys.stderr)
    sys.exit(1)

errors = []

domains = data.get("project_domains") or []
if not isinstance(domains, list):
    errors.append("project_domains must be a list")
else:
    for d in domains:
        if d not in known_domains:
            errors.append(f"unknown project_domain '{d}' (known: {sorted(known_domains)})")

req = data.get("required_subagents") or []
if not isinstance(req, list):
    errors.append("required_subagents must be a list")
else:
    for i, entry in enumerate(req):
        if not isinstance(entry, dict):
            errors.append(f"required_subagents[{i}] must be a mapping")
            continue
        if not isinstance(entry.get("match"), str) or not entry.get("match"):
            errors.append(f"required_subagents[{i}].match must be a non-empty string")
        if not isinstance(entry.get("subagent_type"), str) or not entry.get("subagent_type"):
            errors.append(f"required_subagents[{i}].subagent_type must be a non-empty string")
        if "applies_to" in entry and not isinstance(entry["applies_to"], list):
            errors.append(f"required_subagents[{i}].applies_to must be a list of role names")

rec = data.get("recommended_agents") or []
if not isinstance(rec, list):
    errors.append("recommended_agents must be a list")
else:
    for i, entry in enumerate(rec):
        if not isinstance(entry, dict):
            errors.append(f"recommended_agents[{i}] must be a mapping")
            continue
        if not isinstance(entry.get("subagent_type"), str) or not entry.get("subagent_type"):
            errors.append(f"recommended_agents[{i}].subagent_type must be a non-empty string")
        rel = entry.get("domain_relevance")
        if rel is not None and rel not in known_relevance:
            errors.append(f"recommended_agents[{i}].domain_relevance must be one of {sorted(known_relevance)}")
        if "suitable_for" in entry and not isinstance(entry["suitable_for"], list):
            errors.append(f"recommended_agents[{i}].suitable_for must be a list of role names")

if errors:
    for e in errors:
        print(f"  FAIL: {e}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
    then
      OVERALL=1
      missing=1
    fi
  fi

  if [[ "$missing" == "0" ]]; then
    echo "  OK"
  fi
}

validate_scenarios_json() {
  local f="$1"
  echo "=== validating scenarios.json ==="
  if ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    echo "  FAIL: not a JSON array" >&2
    OVERALL=1
    return 1
  fi
  local bad
  bad=$(jq --argjson kinds "$VALID_E2E_KINDS" '
    [ .[] | select(
        (has("id") | not) or (.id | tostring | test("^E-[0-9]{3}$") | not) or
        (has("name") | not) or (.name | type != "string") or (.name == "") or
        (has("kind") | not) or (.kind as $k | $kinds | index($k) == null) or
        (has("steps") | not) or (.steps | type != "array") or (.steps | length == 0) or
        (has("expected") | not) or (.expected | type != "string") or (.expected == "")
      ) | .id // "<missing-id>"
    ]' "$f")
  local bad_count total
  bad_count=$(echo "$bad" | jq 'length')
  total=$(jq 'length' "$f")
  if [[ "$bad_count" != "0" ]]; then
    echo "  FAIL: $bad_count of $total scenarios failed schema check"
    echo "  Failing IDs: $bad"
    OVERALL=1
  else
    echo "  OK ($total scenarios)"
  fi
}

# Dispatch on target type
if [[ -f "$TARGET" ]]; then
  case "$(basename "$TARGET")" in
    subagent-*.json) validate_reviewer "$TARGET" ;;
    tests.json) validate_tests_json "$TARGET" ;;
    contract.md) validate_contract_md "$TARGET" ;;
    plan.md) validate_plan_md "$TARGET" ;;
    spec.md) validate_spec_md "$TARGET" ;;
    cycle-plan.md) validate_cycle_plan_md "$TARGET" ;;
    agent-config.md) validate_agent_config_md "$TARGET" ;;
    scenarios.json) validate_scenarios_json "$TARGET" ;;
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
      plan.md) validate_plan_md "$f" ;;
      spec.md) validate_spec_md "$f" ;;
      cycle-plan.md) validate_cycle_plan_md "$f" ;;
      agent-config.md) validate_agent_config_md "$f" ;;
      scenarios.json) validate_scenarios_json "$f" ;;
    esac
  done < <(find "$TARGET" \( \
    -name 'subagent-*.json' -o -name 'tests.json' -o -name 'contract.md' \
    -o -name 'plan.md' -o -name 'spec.md' -o -name 'cycle-plan.md' \
    -o -name 'agent-config.md' -o -name 'scenarios.json' \
    \) -type f 2>/dev/null)

  if [[ "$found_any" == "0" ]]; then
    echo "WARN: no recognized artifacts found in $TARGET"
  fi
else
  echo "ERROR: $TARGET is neither a file nor a directory" >&2
  exit 2
fi

exit "$OVERALL"
