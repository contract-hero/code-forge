---
name: code-forge
description: |
  Code Forge v0.2.0 (Option D) — multi-agent build system driven by
  recursive `/goal` sessions. An outer `claude -p /goal` session reads
  spec.md and spawns one `claude -p /goal` per cycle; each cycle child
  runs best-of-N implementer workers and configurable dimensional
  reviewers (count + model + dimensions picked in spec.md). One hook
  survives — test files are read-only during green phase. Use when:
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
  - TaskCreate
  - TaskUpdate
author: alilloig
version: 0.2.0
---

# Code Forge — `/goal`-recursive orchestrator

**`/forge` is just a thin launcher.** The real entry point is
`scripts/forge.sh`, which spawns the **outer Claude session** with an
active `/goal` whose condition is *"every cycle in spec.md ## Cycle Plan
has produced a result.json status: pass."* That outer session is the
orchestrator.

Read `docs/goal-integration.md` for the full protocol. This skill file
is a high-level map.

## The two nested goal sessions

```
top:   claude -p "/goal <outer condition>"    ← spawned by scripts/forge.sh
         │
         ▼ (outer Claude reads spec, picks next cycle, spawns child)
cycle: claude -p "/goal <per-cycle condition>"  ← spawned via Bash
         │
         ▼ (cycle child: tests → red → 6 workers → reviewers → consolidate)
       result.json   ← outer reads, narrates "cycle X status:pass"
```

`/goal` is one-goal-per-session. Session boundaries sidestep the
nested-goal limit: each `claude -p` is a fresh session with its own
evaluator (Haiku by default).

## Phases

**Pre-cycle** (outer Claude drives these in its own session):

| Phase | Owner | Output | Codex gates |
|---|---|---|---|
| 0 — Plan | wraps `codex-bridge:claudex` on the lazy prompt | `.forge/plan.md` | G1 (intrinsic to claudex) |
| 1 — Spec & e2e | dispatches `forge-planner` | `.forge/spec.md` (10 blocks: vision, AC, architecture, E2E Tests, Cycle Plan, /goal Conditions, Reviewer Config, Reviewer Prompt, …) + `.forge/agent-config.md` | G2.a (plan↔spec), G2.b (spec↔e2e) |
| 1.5 — Reviewer Config | planner interactively asks model + dimensions via `AskUserQuestion` | `## Reviewer Config` block in spec.md | — |
| 2 — Cycle Plan | planner internal step (within the same dispatch as Phase 1) | `## Cycle Plan` block in spec.md | G2.5 (optional in `--light`) |

`--quick` skips Phase 0.

**Per cycle** (each cycle is its own `claude -p /goal` child):

1. test-author writes `tests.json` + the actual test files.
2. `cycle-tests-pass.sh red` proves tests fail correctly.
3. State `phase: green` — forge-guard's test-immutability rule activates.
4. Cycle child dispatches N=6 implementer-workers in a single parallel
   turn. Each writes a candidate under `cycles/<id>/green/candidates/`.
5. Cycle child scores candidates (LOC + files + complexity), picks the
   simplest passer, applies to repo.
6. Cycle child dispatches N reviewers in a single parallel turn (count,
   model, and per-reviewer dimension all come from `spec.md ## Reviewer
   Config`).
7. Cycle child dispatches `forge-consolidator` to cluster + verify +
   write `review.md`.
8. Cycle child writes `cycles/<id>/result.json { status: pass | fail,
   ... }`.

The `/goal` evaluator on the cycle child reads transcript and verdicts
"yes" once `result.json status: pass` + `review.md` shows 0 critical
clusters.

## Agents

All dispatchable subagents (Option D dropped both procedure manuals —
`forge-orchestrator` and `implementer` — the outer goal session
and the cycle child do their work inline):

- `forge-planner` — Phase 1 spec authoring (incl. Phase 1.5 interactive
  Reviewer Config sub-step).
- `forge-codebase-explorer` — exploration prompts for extension tasks.
- `forge-test-author` — `tests.json` + actual test files; proves they
  fail at red.
- `forge-implementer-worker` — single best-of-N candidate (model from
  `## Reviewer Config` defaults to sonnet).
- `forge-reviewer` — generic dimensional reviewer parameterized by the
  prompt (no env vars in Option D); the cycle child instantiates one
  reviewer per dimension in `## Reviewer Config`.
- `forge-consolidator` — clusters reviewer findings inline (no
  `_consolidated.json` intermediate in Option D), verifies critical/high
  against source, writes `review.md`.

When you dispatch from inside a cycle child session, `subagent_type` is
always the plugin-namespaced form: `code-forge:forge-planner`,
`code-forge:forge-implementer-worker`, etc.

## Scripts

`${CLAUDE_PLUGIN_ROOT}/scripts/`:

| Script | Use |
|---|---|
| `forge.sh <desc> [--quick] [--light]` | Top-level launcher. Spawns the outer `/goal` session. |
| `cycle-init.sh <cycle-dir>` | Scaffold a cycle dir with `tests.json`, `reviewers/`, `green/candidates/`. |
| `cycle-validate.sh <path>` | Schema validator for `plan.md`, `spec.md`, `tests.json`, `subagent-*.json`, `agent-config.md`, `state.json`, `result.json`. |
| `cycle-tests-pass.sh red\|green <cycle-dir> -- <test-cmd>` | Run the project's test command, write `red.log` / `green.log` + JSON metadata, **invert** exit code for red phase. |
| `forge-status.sh [<forge-dir>]` | Human-readable dashboard. Reads `.forge/state.json` + each cycle's `result.json`. |
| `deploy.sh [--dry-run\|--check]` | Sync the repo's plugin tree to `~/.claude/code-forge/`. |

Dropped in Option D: `cycle-pass.sh` (replaced by `result.json status`),
`cycle-coverage.sh` (no coverage matrix — "list IS the count"),
`cycle-e2e-pass.sh` (no Phase F), `cycle-consolidate.mjs` (consolidator
clusters inline), `e2e-extract.sh` (e2e baked into final cycle's tests).

## Hook

`hooks/forge-guard.mjs` keeps **one rule only**: test files are
read-only during green phase. Edit/Write to a `test_file` path is
blocked; Bash file-writes (redirects, cp/mv, sed -i) targeting the same
paths are blocked too (closes the shell side door). Every other former
rule (contract precedence, single-turn fan-out, post-cycle freeze,
specialist routing, schema auto-validate, advisory phase ordering,
Codex-gate presence advisory) was dropped — those concerns are now
handled by the cycle child's `/goal` condition + procedure.

`/goal` requires the hook subsystem (`disableAllHooks=false` and
`allowManagedHooksOnly` unset). `forge.sh` does **not** check this —
surface the error if it appears at runtime.

## State

`.forge/state.json` (Option D schema, simpler than v0.1.0):

```json
{
  "spec_path": ".forge/spec.md",
  "current_cycle": "C1",
  "phase": "green",
  "light_mode": false,
  "quick_mode": false,
  "cycles": {
    "C1": { "status": "in_progress", "started_at": "..." },
    "C2": { "status": "pending" }
  }
}
```

The cycle child writes `current_cycle` + `phase` (so forge-guard's
green-phase block keys correctly). The outer Claude updates
`cycles[<id>].status` after reading each child's `result.json`.

## Where to look next

- `docs/goal-integration.md` — full outer + cycle-child procedure.
- `templates/spec.md.template` — the 10-block skeleton planner fills in.
- `agents/<name>.md` — per-agent prompt + I/O contract.
- `hooks/forge-guard.mjs` — the surviving rule.
- `tests/smoke.sh` — plugin self-test.

The protocol is intentionally short. Most of code-forge in Option D
lives in spec.md (the cycle plan + /goal conditions + reviewer config),
not in this file.
