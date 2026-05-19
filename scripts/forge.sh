#!/usr/bin/env bash
# Code Forge v0.2.0 (Option D) — top-level launcher.
#
# Usage:
#   scripts/forge.sh <description> [--quick] [--light]
#
# Spawns the outer Claude session with /goal active. The outer session reads
# .forge/spec.md (after Phase 1 has authored it) and dispatches per-cycle
# `claude -p` child sessions until every cycle's result.json reports
# status: pass.
#
# Flags:
#   --quick   Skip Phase 0 (claudex). Use the description verbatim as
#             .forge/plan.md. Trade-off: fewer Codex round-trips for
#             trivial tasks.
#   --light   Skip optional Codex gates (G2.5). Keeps G2.a / G2.b.
#
# Environment:
#   REVIEWERS    Default 6. Per-cycle reviewer count is read from
#                spec.md ## Reviewer Config.dimensions length — this env
#                var is no longer used in Option D and is preserved only
#                for documentation parity with prior versions.
#   IMPLEMENTERS Default 6. Number of best-of-N workers each cycle
#                dispatches.
#   K_OUTER      Default len(cycles)+5. Outer goal turn cap. Computed at
#                runtime; override only when debugging.
#   K_CHILD      Default 30. Per-cycle goal turn cap.
#
# Requires:
#   claude >= v2.1.139 (for /goal support)
#   forge-guard hook active (settings.json must not set disableAllHooks)

set -u
set -o pipefail

# Parse flags off the front of the argument list. Everything else becomes the
# task description.
QUICK=0
LIGHT=0
ARGS=()

while (("$#")); do
  case "$1" in
    --quick) QUICK=1; shift ;;
    --light) LIGHT=1; shift ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ ${#ARGS[@]} -eq 0 ]]; then
  echo "Usage: scripts/forge.sh <description> [--quick] [--light]" >&2
  exit 2
fi

DESCRIPTION="${ARGS[*]}"

# --- Pre-flight checks ---------------------------------------------------

# Require Claude Code v2.1.139+ (for /goal).
CLAUDE_VERSION="$(claude --version 2>/dev/null | head -1 | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/' || echo "0.0.0")"
if [[ -z "$CLAUDE_VERSION" || "$CLAUDE_VERSION" == "0.0.0" ]]; then
  echo "ERROR: cannot detect 'claude' CLI version. /goal requires v2.1.139+." >&2
  exit 2
fi

# Numeric compare: any 2.x.x where (major,minor,patch) >= (2,1,139).
IFS='.' read -r MAJ MIN PAT <<<"$CLAUDE_VERSION"
if (( MAJ < 2 )) \
    || (( MAJ == 2 && MIN < 1 )) \
    || (( MAJ == 2 && MIN == 1 && PAT < 139 )); then
  echo "ERROR: claude --version reports $CLAUDE_VERSION; /goal requires v2.1.139+." >&2
  exit 2
fi

# Bootstrap .forge/ if absent.
mkdir -p .forge

# Phase 0 — Plan
if [[ "$QUICK" == "1" ]]; then
  if [[ ! -s .forge/plan.md ]]; then
    {
      echo "# Plan"
      echo
      echo "$DESCRIPTION"
    } > .forge/plan.md
    echo "→ wrote .forge/plan.md (--quick: verbatim description)" >&2
  fi
else
  if [[ ! -s .forge/plan.md ]]; then
    # The outer session's first turn will wrap codex-bridge:claudex on the
    # description. forge.sh writes a stub so the spec authoring step has
    # something to read; the outer Claude can edit it after running claudex.
    {
      echo "# Plan"
      echo
      echo "<!-- forge.sh stub: outer Claude will refine this via codex-bridge:claudex -->"
      echo
      echo "$DESCRIPTION"
    } > .forge/plan.md
    echo "→ wrote .forge/plan.md (stub; outer session will refine via claudex)" >&2
  fi
fi

# Seed state.json. The outer Claude updates this as cycles run.
if [[ ! -s .forge/state.json ]]; then
  cat > .forge/state.json << JSON
{
  "spec_path": ".forge/spec.md",
  "current_cycle": null,
  "phase": "plan",
  "light_mode": $([[ "$LIGHT" == "1" ]] && echo true || echo false),
  "quick_mode": $([[ "$QUICK" == "1" ]] && echo true || echo false),
  "cycles": {}
}
JSON
  echo "→ initialized .forge/state.json" >&2
fi

# --- Outer goal condition ------------------------------------------------

# K_OUTER auto-sizes to "expected cycles + 5" once spec.md exists. Before
# Phase 1 we can't know cycle count, so seed with a conservative ceiling
# (40 turns) — the outer goal narrates ahead-of-Phase-1 anyway.
K_OUTER="${K_OUTER:-40}"

read -r -d '' OUTER_GOAL << 'GOAL' || true
After authoring spec.md (Phase 1, with the interactive Reviewer Config
sub-step at Phase 1.5), every cycle id listed in
.forge/spec.md ## Cycle Plan has produced a corresponding
cycles/<id>/result.json file containing status: pass — as observed in
this session's transcript via narration of each child session's exit —
GOAL

OUTER_GOAL="${OUTER_GOAL}or stop after ${K_OUTER} outer turns"

# --- Spawn the outer session --------------------------------------------

# Pass the flag context + the lazy prompt as the initial user message;
# /goal is the persistent stop condition.

PROMPT="$(cat <<MSG
You are the outer Claude session for Code Forge v0.2.0 (Option D).

Read docs/goal-integration.md for the full protocol. Highlights:
  - Phase 0 (skip if --quick): wrap codex-bridge:claudex on the lazy
    prompt, land .forge/plan.md.
  - Phase 1: dispatch forge-planner. It writes .forge/spec.md (with all
    10 required blocks) and .forge/agent-config.md, running G2.a / G2.b
    Codex loops + the interactive Phase 1.5 Reviewer Config sub-step.
  - Cycle loop: for each pending cycle in spec.md ## Cycle Plan, spawn
    a child via Bash:
        claude -p "<cycle's goal_condition>" --add-dir .forge \\
            --add-dir <files_affected paths>
    Wait for child exit, read cycles/<id>/result.json, narrate the
    status in transcript so the outer evaluator can see it.

Flags from forge.sh: --quick=${QUICK} --light=${LIGHT}.

Lazy prompt: ${DESCRIPTION}
MSG
)"

# /goal "<condition>" makes the slash-command set the goal; the rest of
# PROMPT is the lazy task. Newer Claude versions accept the slash command
# as the very first line of the headless prompt.
exec claude -p "/goal ${OUTER_GOAL}

${PROMPT}" \
  --add-dir .forge \
  --add-dir scripts \
  --add-dir agents
