---
name: code-forge
description: |
  Multi-agent build system driven by recursive `/goal` orchestration. You
  are the orchestrator — this skill drives Phase 0 (claudex), Phase 1
  (planner authors spec.md with all required blocks), then spawns one
  `claude -p /goal` per cycle. Each cycle child runs best-of-N implementer
  workers and configurable dimensional reviewers. One PreToolUse hook
  keeps test files read-only during green. Use when:
  (1) the user invokes `/forge`,
  (2) the user wants to start a new PoC/MVP from a brief description,
  (3) the user wants a structured multi-cycle build with TDD discipline
      and parallel review.
allowed-tools:
  - mcp__codex__codex
  - mcp__codex__codex-reply
  - AskUserQuestion
  - Agent
  - Write
  - Read
  - Edit
  - Bash
  - Glob
  - Grep
author: alilloig
version: 0.2.0
---

# Code Forge

You are the **outer orchestrator** for Code Forge. `/forge` has just been
invoked with the user's task description. Drive the protocol in this
interactive session: author the spec, then loop over cycles spawning
`claude -p /goal` per cycle.

**Lazy prompt:** $ARGUMENTS

Parse flags from `$ARGUMENTS` (strip them before passing the description
to Phase 0):
- `--quick` — skip Phase 0; use the description verbatim as `plan.md`.
- `--light` — skip the optional Codex G2.5 gate. Keeps G2.a / G2.b.
- `--resume` — allow reuse of an existing `.forge/` directory.

## Pre-flight

Before any phase work:

1. **Claude version**. Run `claude --version`. Require **v2.1.139+**
   (the minimum that supports `/goal`). On a lower version, halt with a
   clear error message — the per-cycle children depend on `/goal`.
2. **Stale `.forge/` check**. If `.forge/state.json` already exists and
   the user did not pass `--resume`, ask with `AskUserQuestion` whether
   to:
   - Resume the existing run (treat as if `--resume` was passed).
   - Wipe `.forge/` and start fresh.
   - Abort.
3. **`mkdir -p .forge/`** if it doesn't exist.

## Phase 0 — Plan

Skip if `--quick` was passed; in that case write the lazy prompt
verbatim into `.forge/plan.md`.

Otherwise, invoke the `codex-bridge:claudex` skill on the lazy prompt.
It runs multi-round Claude ↔ Codex refinement and lands a refined plan
in plan mode. Capture the refined prompt as `.forge/plan.md`.

Validate: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/cycle-validate.sh .forge/plan.md`.

## Phase 1 — Spec & e2e

Dispatch the **`forge-planner`** subagent
(`subagent_type: "code-forge:forge-planner"`) with `.forge/plan.md` as
input. The planner:

- Authors `.forge/spec.md` with all required blocks (Vision, Acceptance
  Criteria, Architecture, E2E Tests, Cycle Plan, Reviewer Config). See
  `templates/spec.md.template`.
- Runs internal Codex iteration gates (G2.a spec ↔ plan, G2.b spec ↔
  e2e, optionally G2.5 cycle-plan ↔ spec unless `--light`).
- Runs the interactive **Phase 1.5 Reviewer Config sub-step**
  (model + dimensions via `AskUserQuestion`).
- Emits `.forge/agent-config.md` for routing hints.
- **Mirrors each cycle's `goal_condition`** from `spec.md ## Cycle Plan`
  into `state.json.cycles[<id>].goal_condition` so the cycle loop can
  read it via `jq`.

Wait for the planner subagent to complete. Validate:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/cycle-validate.sh .forge/spec.md
bash ${CLAUDE_PLUGIN_ROOT}/scripts/cycle-validate.sh .forge/agent-config.md
```

## Cycle loop

Iterate over cycles in `.forge/spec.md ## Cycle Plan` order. For each
cycle id, in sequence:

1. **Skip-if-done.** Read `.forge/state.json`. If
   `cycles[<id>].status == "pass"`, skip to the next cycle.
2. **Mark in-progress.** Update `state.json`:
   `current_cycle = "<id>"`, `cycles[<id>].status = "in_progress"`,
   `cycles[<id>].started_at = <now>`.
3. **Read the cycle's `goal_condition`** from state.json (the planner
   mirrored it there at Phase 1).
4. **Spawn the cycle child** via Bash:

   ```bash
   claude -p "/goal ${CYCLE_GOAL}" \
     --add-dir .forge \
     --add-dir <files_affected from spec.md cycle plan entry>
   ```

   `claude -p` runs to completion (the per-cycle child's `/goal`
   eventually clears or times out). Capture the exit code.
5. **Read `cycles/<id>/result.json`**.
   - If the file exists and `status == "pass"`: narrate
     "Cycle `<id>` complete with status=pass" in transcript. Update
     `state.json.cycles[<id>].status = "pass"` and continue to the
     next cycle.
   - If the file exists and `status == "fail"`: surface the failure to
     the user (cite `cycles/<id>/review.md` for the cluster summary).
     Update `state.json.cycles[<id>].status = "fail"`. **Halt the
     loop** — do not auto-continue past a failed cycle.
   - If the file does not exist (cycle child crashed before writing
     it): synthesize a `result.json` with `status: "fail"`,
     `summary: "cycle child crashed (exit N) before writing result.json"`.
     Surface to user. Halt the loop.

Each cycle child has its own `/goal` condition and its own Haiku
evaluator; this skill (in the user's interactive session) only manages
the cycle loop and cycle-child spawning.

## Done

When every cycle in the plan has `status: "pass"`:

- Print a summary citing each cycle's `result.json` summary and
  `review.md` path.
- Note any high/medium findings the user may want to address even
  though the cycle passed (critical=0 is the gate; non-criticals can
  still be worth a follow-up).

If the loop halted on a failure, surface the failing cycle's
`review.md` and tell the user how to investigate + re-invoke `/forge`
with `--resume` after addressing the issue.

## Subagents (dispatchable from this session)

When you call the `Agent` tool, `subagent_type` is always the
plugin-namespaced form. See `agents/<name>.md` for each role's prompt
and I/O contract:

- `code-forge:forge-planner` — Phase 1 spec authoring (incl. Phase 1.5
  interactive Reviewer Config sub-step).
- `code-forge:forge-test-author` — `tests.json` + actual test files.
- `code-forge:forge-implementer-worker` — single best-of-N candidate
  (model from spec's Reviewer Config defaults to sonnet).
- `code-forge:forge-reviewer` — generic dimensional reviewer
  (parameterized by the assigned dimension passed in the prompt).
- `code-forge:forge-consolidator` — clusters reviewer findings inline,
  verifies critical/high against source, writes `review.md`.

The cycle child spawns these subagents itself; this skill only spawns
the cycle child via `claude -p /goal`.

## Scripts

`${CLAUDE_PLUGIN_ROOT}/scripts/`:

- `cycle-init.sh <cycle-dir>` — scaffold a cycle directory.
- `cycle-validate.sh <path>` — schema validator for every artifact
  (plan.md, spec.md, tests.json, subagent-*.json, agent-config.md,
  state.json, result.json).
- `cycle-tests-pass.sh red|green <cycle-dir> -- <test-cmd>` — red/green
  truth gate. Inverts exit code for red phase so tautological tests
  fail the gate.
- `forge-status.sh [<forge-dir>]` — human-readable dashboard. The user
  can run it anytime to inspect a partial run.

## Hook (one rule)

`hooks/forge-guard.mjs` blocks Edit/Write/Bash writes that would weaken
the test suite during green phase. Coverage spans the test_file paths,
the `.forge/state.json` + `.forge/cycles/<id>/tests.json` anchors
themselves, and an extensive Bash side-door regex (sed -i GNU + BSD,
perl/ruby/awk in-place, cp/mv/install with -t form, dd, truncate,
ln -sf, rm, plus sh -c / bash -c / eval / here-string invocations
referencing those paths). Fail-closed on any internal error.

Hooks must be enabled (`disableAllHooks: false` in settings). Without
this hook, `/goal "tests pass"` would happily rewrite the tests.

## State schema

`.forge/state.json`:

```json
{
  "spec_path": ".forge/spec.md",
  "current_cycle": "C1",
  "phase": "green",
  "light_mode": false,
  "quick_mode": false,
  "cycles": {
    "C1": {
      "status": "in_progress",
      "started_at": "...",
      "goal_condition": "cycles/C1/result.json exists with status: pass AND review.md has 0 critical clusters, or stop after 30 turns"
    },
    "C2": { "status": "pending", "goal_condition": "..." }
  }
}
```

Writers:
- This skill seeds the initial document and updates `current_cycle` +
  `cycles[<id>].status` between cycle spawns.
- The planner mirrors each cycle's `goal_condition` after Phase 1.
- The cycle child writes `phase` and reads `goal_condition`.

## Where to look next

- `docs/goal-integration.md` — narrative protocol (this skill + cycle
  child procedures).
- `templates/spec.md.template` — the 10-block skeleton planner fills in.
- `agents/<name>.md` — per-agent I/O contract.
- `hooks/forge-guard.mjs` — the surviving rule.
