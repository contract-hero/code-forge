#!/usr/bin/env bash
# Code Forge v0.2.0 (Option D) — top-level launcher.
#
# Usage:
#   scripts/forge.sh <description> [--quick] [--light] [--resume]
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
#   --light   Skip the optional Codex G2.5 gate. Keeps G2.a / G2.b.
#   --resume  Allow reuse of an existing .forge/ directory. Without this
#             flag, a non-empty .forge/state.json triggers an explicit
#             error so a stale-state run can't silently mis-fire the
#             forge-guard hook against the wrong cycle.
#
# Environment:
#   K_OUTER   Default 40. Outer goal turn cap. Override to len(cycles)+5
#             once spec.md is authored; see docs/goal-integration.md.
#
# Requires:
#   claude >= v2.1.139 (for /goal support)
#   forge-guard hook active (settings.json must not set disableAllHooks)

set -eu
set -o pipefail

# Parse flags off the front of the argument list. Everything else becomes the
# task description.
QUICK=0
LIGHT=0
RESUME=0
ARGS=()

while (("$#")); do
  case "$1" in
    --quick)  QUICK=1; shift ;;
    --light)  LIGHT=1; shift ;;
    --resume) RESUME=1; shift ;;
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

# Require Claude Code v2.1.139+ (for /goal). Parse strictly: `sed -n .. p`
# emits nothing on a non-match, so the empty/0.0.0 guard fires correctly.
CLAUDE_VERSION="$(claude --version 2>/dev/null | head -1 \
  | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
if [[ -z "$CLAUDE_VERSION" ]]; then
  echo "ERROR: cannot detect 'claude' CLI version. /goal requires v2.1.139+." >&2
  exit 2
fi
if [[ ! "$CLAUDE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: 'claude --version' produced unexpected output: $CLAUDE_VERSION" >&2
  exit 2
fi

IFS='.' read -r MAJ MIN PAT <<<"$CLAUDE_VERSION"
if (( MAJ < 2 )) \
    || (( MAJ == 2 && MIN < 1 )) \
    || (( MAJ == 2 && MIN == 1 && PAT < 139 )); then
  echo "ERROR: claude --version reports $CLAUDE_VERSION; /goal requires v2.1.139+." >&2
  exit 2
fi

# Refuse to reuse a stale .forge/ unless --resume. Without this gate, a
# previous run's state.json (with `phase: green`, `current_cycle: C2`, etc.)
# silently mis-fires the forge-guard hook against the new task's files.
if [[ -s .forge/state.json && "$RESUME" != "1" ]]; then
  echo "ERROR: .forge/state.json already exists. Pass --resume to continue an" >&2
  echo "       in-flight run, or remove .forge/ to start fresh." >&2
  exit 2
fi
if [[ -s .forge/state.json && "$RESUME" == "1" ]]; then
  # Validate the stale state.json before we trust it.
  if ! bash "$(dirname "$0")/cycle-validate.sh" .forge/state.json >/dev/null 2>&1; then
    echo "ERROR: existing .forge/state.json failed cycle-validate.sh. Fix or" >&2
    echo "       remove it before retrying with --resume." >&2
    exit 2
  fi
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
# We omit `phase` deliberately — no consumer treats "plan" specially, and
# leaving it unset lets the cycle child be the first writer of a phase the
# forge-guard hook actually keys on (phase=="green").
if [[ ! -s .forge/state.json ]]; then
  cat > .forge/state.json << JSON
{
  "spec_path": ".forge/spec.md",
  "current_cycle": null,
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

read -r -d '' OUTER_GOAL << GOAL || true
After authoring spec.md (Phase 1, with the interactive Reviewer Config
sub-step at Phase 1.5), every cycle id listed in
.forge/spec.md ## Cycle Plan has produced a corresponding
cycles/<id>/result.json file containing status: pass — as observed in
this session's transcript via narration of each child session's exit —
or stop after ${K_OUTER} outer turns
GOAL

# --- Spawn the outer session --------------------------------------------

# Pass the flag context + the lazy prompt as the initial user message;
# /goal is the persistent stop condition.

PROMPT="$(cat <<MSG
You are the outer Claude session for Code Forge v0.2.0 (Option D).

Read skills/code-forge/SKILL.md and docs/goal-integration.md for the
protocol. The cycle plan + per-cycle goal_conditions live in
.forge/spec.md ## Cycle Plan once Phase 1 has authored it.

Flags from forge.sh: --quick=${QUICK} --light=${LIGHT} --resume=${RESUME}.

Lazy prompt: ${DESCRIPTION}
MSG
)"

# /goal "<condition>" makes the slash-command set the goal; the rest of
# PROMPT is the lazy task. Newer Claude versions accept the slash command
# as the very first line of the headless prompt.
command -v claude >/dev/null 2>&1 || {
  echo "ERROR: 'claude' command vanished between preflight and launch." >&2
  exit 2
}
exec claude -p "/goal ${OUTER_GOAL}

${PROMPT}" \
  --add-dir .forge \
  --add-dir scripts \
  --add-dir agents
