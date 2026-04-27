#!/usr/bin/env bash
# e2e-extract.sh — parse spec.md's ## E2E Tests section into scenarios.json.
#
# Usage: e2e-extract.sh <spec.md> <out-scenarios.json>
#
# The ## E2E Tests section is expected to be a YAML-ish list of scenarios in
# the schema described in spec §7.4 (id, name, kind, preconditions, steps,
# expected, covers_contract, tooling). The section may be enclosed in a
# fenced ```yaml block or live as a free-form list of `-` items; both are
# accepted as long as the body parses as YAML.
#
# This script is intentionally minimal — it does NOT build scenarios out of
# free-text Gherkin. Authors writing the spec are expected to use the
# structured shape from §7.4. Validation lives in cycle-validate.sh.
#
# Requires: python3. PyYAML is optional; without it the script falls back to
# a tiny line-based parser sufficient for the documented shape.

set -u
set -o pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: e2e-extract.sh <spec.md> <out-scenarios.json>" >&2
  exit 2
fi

SPEC="$1"
OUT="$2"

if [[ ! -f "$SPEC" ]]; then
  echo "ERROR: spec not found: $SPEC" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 required" >&2
  exit 2
fi

mkdir -p "$(dirname "$OUT")"

python3 - "$SPEC" "$OUT" <<'PY'
import sys, re, json, os

spec_path, out_path = sys.argv[1], sys.argv[2]

with open(spec_path) as fh:
    text = fh.read()

# Find the ## E2E Tests section body — everything from that heading until
# the next H2 heading or EOF.
m = re.search(r"^##\s+E2E Tests\s*$", text, re.M)
if not m:
    print("ERROR: spec.md has no '## E2E Tests' section", file=sys.stderr)
    sys.exit(1)
start = m.end()
nxt = re.search(r"^##\s+\S", text[start:], re.M)
body = text[start:start + nxt.start()] if nxt else text[start:]

# Strip any fenced ```yaml … ``` wrapper.
fence = re.search(r"```(?:yaml|yml)?\s*\n([\s\S]*?)```", body)
if fence:
    body = fence.group(1)

scenarios = None

# Try PyYAML first.
try:
    import yaml
    scenarios = yaml.safe_load(body)
except ImportError:
    pass

def _coerce(s):
    s = s.strip()
    if (s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'")):
        return s[1:-1]
    if s.startswith("[") and s.endswith("]"):
        inner = s[1:-1].strip()
        if not inner:
            return []
        return [x.strip().strip('"').strip("'") for x in inner.split(",")]
    return s

# Fallback parser: scan for top-level "- id: …" entries and capture each
# entry's keys. Sufficient for the structured schema; any non-trivial YAML
# (anchors, multi-line scalars beyond simple strings) requires PyYAML.
if scenarios is None:
    scenarios = []
    current = None
    list_key = None
    for raw in body.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m_top = re.match(r"^-\s+(\w+):\s*(.*)$", line)
        if m_top:
            if current is not None:
                scenarios.append(current)
            current = {}
            list_key = None
            key, val = m_top.group(1), m_top.group(2).strip()
            if val == "":
                current[key] = []
                list_key = key
            else:
                current[key] = _coerce(val)
            continue
        m_sub = re.match(r"^\s+(\w+):\s*(.*)$", line)
        if m_sub and current is not None:
            key, val = m_sub.group(1), m_sub.group(2).strip()
            list_key = None
            if val == "":
                current[key] = []
                list_key = key
            else:
                current[key] = _coerce(val)
            continue
        m_item = re.match(r"^(\s+)-\s+(.*)$", line)
        if m_item and current is not None and list_key is not None:
            value = _coerce(m_item.group(2).strip())
            current[list_key].append(value)
            continue
    if current is not None:
        scenarios.append(current)

if not isinstance(scenarios, list):
    print("ERROR: ## E2E Tests body did not parse to a list", file=sys.stderr)
    sys.exit(1)

# Normalize: drop empty entries, default missing optional fields.
out = []
for sc in scenarios:
    if not isinstance(sc, dict):
        continue
    sc.setdefault("preconditions", [])
    sc.setdefault("steps", sc.get("steps", []))
    sc.setdefault("expected", "")
    sc.setdefault("covers_contract", [])
    sc.setdefault("tooling", None)
    out.append(sc)

os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
with open(out_path, "w") as fh:
    json.dump(out, fh, indent=2)
    fh.write("\n")

print(f"wrote {len(out)} scenario(s) → {out_path}")
PY
