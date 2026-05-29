#!/usr/bin/env bash
# Strict schema validator for forge cycle artifacts (Option D).
#
# Usage: cycle-validate.sh <path>
#   <path> can be:
#     - a directory tree — every recognized artifact is validated
#     - a single .json or .md file — that file is validated
#
# Recognized artifacts (Option D set):
#   - subagent-N.json    reviewer findings, strict schema
#   - tests.json         test list (test-author phase)
#   - plan.md            non-empty + has H1 title
#   - spec.md            has required sections (Vision, Architecture, AC,
#                        E2E Tests, Cycle Plan, Reviewer Config)
#   - agent-config.md    YAML frontmatter with project_domains,
#                        required_subagents, recommended_agents
#   - state.json         phase + current_cycle + cycles[*].status enums
#   - result.json        status, cycle_id, summary, review_clusters
#
# Exits non-zero if any artifact fails validation.
#
# Requires: jq.

set -u
set -o pipefail

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
VALID_CATEGORIES='["correctness","design","error-handling","simplicity","tests-vs-impl","dependencies","security","performance","documentation","build","naming-readability","dependency-hygiene","type-safety","concurrency","observability","sui-move-idioms","frontend-a11y","api-contract-stability"]'
VALID_TEST_KINDS='["unit","integration","property"]'
VALID_PHASES='["plan","spec","cycle-plan","contract","test-list","red","green","review","done"]'
VALID_CYCLE_STATUS='["pending","in_progress","pass","fail"]'
VALID_RESULT_STATUS='["pass","fail"]'
VALID_DOMAIN_RELEVANCE='["high","medium","low"]'
KNOWN_PROJECT_DOMAINS='["sui-dapp","walrus","seal","sui-cli"]'

OVERALL=0

# NOTE (PR #1): the authoritative findings gate is now FINDINGS_SCHEMA in
# workflows/review-stage.mjs (enforced at dispatch by the review Workflow).
# This function is retained for forge-smoke fixtures and as belt-and-suspenders
# on persisted subagent-*.json; it is no longer the primary findings gate.
validate_reviewer() {
  local f="$1"
  local n
  # POSIX-portable: use [0-9][0-9]* instead of GNU-only \+.
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

  local total
  total=$(jq 'length' "$f")
  # Reject empty tests.json — a cycle with no tests is not a valid contract,
  # and cycle-init.sh's `[]` stub should be replaced by the test-author.
  if [[ "$total" == "0" ]]; then
    echo "  FAIL: tests.json is empty (cycle has zero tests authored)" >&2
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

  local bad_count
  bad_count=$(echo "$bad" | jq 'length')
  if [[ "$bad_count" != "0" ]]; then
    echo "  FAIL: $bad_count of $total tests failed schema check"
    echo "  Failing IDs: $bad"
    OVERALL=1
  else
    echo "  OK ($total tests)"
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

# Strip fenced code blocks from a file before grepping for headings. Prevents
# spec examples (triple-backtick blocks) from being mistaken for real
# section headings.
strip_fenced_blocks() {
  awk '
    BEGIN { in_fence = 0 }
    /^```/ { in_fence = 1 - in_fence; next }
    !in_fence { print }
  ' "$1"
}

validate_spec_md() {
  local f="$1"
  echo "=== validating spec.md ==="
  if [[ ! -s "$f" ]]; then
    echo "  FAIL: spec.md is empty or missing"
    OVERALL=1
    return 1
  fi
  local stripped
  stripped=$(strip_fenced_blocks "$f")
  local missing=0
  if ! printf '%s\n' "$stripped" | grep -qE '^# '; then
    echo "  FAIL: missing H1 title"
    missing=1
  fi
  # Option D required sections. Use exact-heading match (`^${section}( |$)`)
  # so '## Reviewer Configuration' does not satisfy '## Reviewer Config'.
  for section in "## Vision" "## Acceptance Criteria" "## Architecture" "## E2E Tests" "## Cycle Plan" "## Reviewer Config"; do
    if ! printf '%s\n' "$stripped" | grep -qE "^${section}( |$)"; then
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
  local missing_keys=0
  for key in "project_domains" "required_subagents" "recommended_agents"; do
    if ! echo "$fm" | grep -qE "^${key}:"; then
      echo "  FAIL: missing required frontmatter key '${key}'"
      missing_keys=1
    fi
  done
  if [[ "$missing_keys" == "1" ]]; then
    OVERALL=1
    return 1
  fi

  # Deeper schema check via PyYAML if available.
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
      return 1
    fi
  fi

  echo "  OK"
}

validate_state_json() {
  # Option D state.json schema: spec_path, current_cycle, phase, light_mode,
  # quick_mode, cycles{}. Validate the load-bearing fields' shape + enums.
  local f="$1"
  echo "=== validating state.json ==="
  if ! jq -e '.' "$f" >/dev/null 2>&1; then
    echo "  FAIL: not parseable JSON" >&2
    OVERALL=1
    return 1
  fi

  # phase must be a known enum value if present.
  if jq -e 'has("phase")' "$f" >/dev/null 2>&1; then
    local phase_ok
    phase_ok=$(jq --argjson allowed "$VALID_PHASES" '
      (.phase | type == "string") and (.phase as $p | $allowed | index($p) != null)
    ' "$f")
    if [[ "$phase_ok" != "true" ]]; then
      echo "  FAIL: state.phase must be a string in $VALID_PHASES" >&2
      OVERALL=1
      return 1
    fi
  fi

  # cycles{*}.status must be a known enum if cycles is present.
  if jq -e 'has("cycles") and (.cycles | type == "object")' "$f" >/dev/null 2>&1; then
    local bad_statuses
    bad_statuses=$(jq --argjson allowed "$VALID_CYCLE_STATUS" '
      [ .cycles | to_entries[] | select(
          (.value | has("status") | not) or
          ((.value.status | type) != "string") or
          (.value.status as $s | $allowed | index($s) == null)
        ) | .key ]
    ' "$f")
    local bad_count
    bad_count=$(echo "$bad_statuses" | jq 'length')
    if [[ "$bad_count" != "0" ]]; then
      echo "  FAIL: cycles entries with bad status: $bad_statuses (allowed: $VALID_CYCLE_STATUS)" >&2
      OVERALL=1
      return 1
    fi
  fi

  echo "  OK"
}

validate_result_json() {
  # Option D: each cycle child writes result.json with status, cycle_id,
  # summary, review_clusters before exiting. The outer /goal evaluator reads
  # status: pass to verdict; forge-status reads review_clusters.{critical,high}.
  local f="$1"
  echo "=== validating result.json ==="
  if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    echo "  FAIL: not a JSON object" >&2
    OVERALL=1
    return 1
  fi

  local missing=0
  local status
  status=$(jq -r '.status // ""' "$f" 2>/dev/null || echo "")
  if [[ "$status" != "pass" && "$status" != "fail" ]]; then
    echo "  FAIL: status must be \"pass\" or \"fail\" (got: \"$status\")"
    missing=1
  fi
  if ! jq -e 'has("cycle_id") and (.cycle_id | type == "string") and (.cycle_id != "")' "$f" >/dev/null 2>&1; then
    echo "  FAIL: missing or empty cycle_id (string required)"
    missing=1
  fi
  if ! jq -e 'has("summary") and (.summary | type == "string") and (.summary != "")' "$f" >/dev/null 2>&1; then
    echo "  FAIL: missing or empty summary"
    missing=1
  fi
  if ! jq -e 'has("review_clusters") and (.review_clusters | type == "object")' "$f" >/dev/null 2>&1; then
    echo "  FAIL: missing or non-object review_clusters"
    missing=1
  else
    if ! jq -e '.review_clusters | has("critical") and (.critical | type == "number")' "$f" >/dev/null 2>&1; then
      echo "  FAIL: review_clusters.critical must be an integer"
      missing=1
    fi
    if ! jq -e '.review_clusters | has("high") and (.high | type == "number")' "$f" >/dev/null 2>&1; then
      echo "  FAIL: review_clusters.high must be an integer"
      missing=1
    fi
  fi
  if [[ "$status" == "pass" ]]; then
    if ! jq -e '.review_clusters.critical == 0' "$f" >/dev/null 2>&1; then
      echo "  FAIL: status:pass requires review_clusters.critical == 0"
      missing=1
    fi
  fi
  if [[ "$missing" == "0" ]]; then
    echo "  OK"
  else
    OVERALL=1
  fi
}

# Dispatch on target type
if [[ -f "$TARGET" ]]; then
  case "$(basename "$TARGET")" in
    subagent-*.json)  validate_reviewer "$TARGET" ;;
    tests.json)       validate_tests_json "$TARGET" ;;
    plan.md)          validate_plan_md "$TARGET" ;;
    spec.md)          validate_spec_md "$TARGET" ;;
    agent-config.md)  validate_agent_config_md "$TARGET" ;;
    state.json)       validate_state_json "$TARGET" ;;
    result.json)      validate_result_json "$TARGET" ;;
    *) echo "ERROR: don't know how to validate $TARGET" >&2; exit 2 ;;
  esac
elif [[ -d "$TARGET" ]]; then
  found_any=0
  while IFS= read -r f; do
    found_any=1
    case "$(basename "$f")" in
      subagent-*.json)  validate_reviewer "$f" ;;
      tests.json)       validate_tests_json "$f" ;;
      plan.md)          validate_plan_md "$f" ;;
      spec.md)          validate_spec_md "$f" ;;
      agent-config.md)  validate_agent_config_md "$f" ;;
      state.json)       validate_state_json "$f" ;;
      result.json)      validate_result_json "$f" ;;
    esac
  done < <(find "$TARGET" \( \
    -name 'subagent-*.json' -o -name 'tests.json' \
    -o -name 'plan.md' -o -name 'spec.md' \
    -o -name 'agent-config.md' \
    -o -name 'state.json' -o -name 'result.json' \
    \) -type f 2>/dev/null)

  if [[ "$found_any" == "0" ]]; then
    echo "WARN: no recognized artifacts found in $TARGET"
  fi
else
  echo "ERROR: $TARGET is neither a file nor a directory" >&2
  exit 2
fi

exit "$OVERALL"
