#!/usr/bin/env bash
# Print a file × reviewer coverage matrix from reviewer JSON findings.
#
# Direct port of move-pr-review's coverage_matrix.sh, defaults adjusted for forge:
#   - REVIEWERS default 6 (was 10)
#   - COVERAGE_FLOOR default 3 of 6 (50%) — was 5 of 10
#   - Reads from cycles/<n>/reviewers/ + cycles/<n>/contract.md scope list
#
# Usage: cycle-coverage.sh <reviewers-dir> [<scope-files>] [<floor>]
#   <reviewers-dir> e.g. .forge/cycles/1/reviewers
#   <scope-files>   defaults to <reviewers-dir>/../_scope_files.txt
#   <floor>         default 3 (files below get flagged for R0 backfill)
#
# Files with < floor reviewer touches are flagged with "*".
#
# Env:
#   REVIEWERS — total reviewers (default 6)
#
# Requires: jq.

set -u
set -o pipefail

REVIEWERS_DIR="${1:-.forge/cycles/1/reviewers}"
SCOPE_FILES="${2:-${REVIEWERS_DIR}/../_scope_files.txt}"
COVERAGE_FLOOR="${3:-3}"
REVIEWERS="${REVIEWERS:-6}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found in PATH" >&2
  exit 2
fi
if [[ ! -f "$SCOPE_FILES" ]]; then
  echo "ERROR: scope file list not found: $SCOPE_FILES" >&2
  exit 2
fi

srcs=()
for n in $(seq 1 "$REVIEWERS"); do
  [[ -f "$REVIEWERS_DIR/subagent-$n.json" ]] && srcs+=("$REVIEWERS_DIR/subagent-$n.json")
done

{
  if [[ "${#srcs[@]}" -gt 0 ]]; then
    jq -r '
      (input_filename | capture("subagent-(?<n>[0-9]+)") | .n) as $rev
      | group_by(.file)[]
      | "C\t\($rev)\t\(.[0].file)\t\(length)"
    ' "${srcs[@]}"
  fi
  sed 's/^/F\t/' "$SCOPE_FILES"
} | awk -F'\t' -v floor="$COVERAGE_FLOOR" -v reviewers="$REVIEWERS" '
  BEGIN {
    OFS = "\t"
    header = "file"
    for (i = 1; i <= reviewers; i++) header = header OFS "R" i
    header = header OFS "total" OFS "flag"
    print header
  }
  $1 == "C" { counts[$3, $2] = $4; next }
  $1 == "F" && $2 != "" {
    fp = $2
    total = 0; touched = 0
    row = fp
    for (n = 1; n <= reviewers; n++) {
      c = (fp SUBSEP n) in counts ? counts[fp, n] : 0
      row = row OFS c
      total += c
      if (c > 0) touched++
    }
    flag = (touched < floor) ? "*" : ""
    print row, total, flag
  }
  END {
    print ""
    print "Files marked with * have < " floor " reviewer touches out of " reviewers " — orchestrator should backfill via R0 (leader)."
  }
'
