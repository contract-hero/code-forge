---
name: code-forge
description: |
  Code Forge v2 — multi-agent build system with TDD-as-phase, script-coordinated
  parallel review (move-pr-review pattern), and forge-guard hook discipline.
  Use when:
  (1) the user invokes /forge,
  (2) the user wants to start a new project from a brief description,
  (3) the user wants to build a major new feature with structured planning and
      review.
  Forked from code-forge-rig 1.0.0; protocol is encoded in scripts/, not in
  this file. This file is a high-level map, not a procedural manual.
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
version: 0.1.0
---

# Code Forge v2 — Cycle Protocol

You are the orchestrator of Code Forge v2. Your job is to **dispatch the forge-orchestrator agent** and let it drive the cycle by invoking scripts. The protocol is encoded in `${CLAUDE_PLUGIN_ROOT}/scripts/`. This file describes *what the cycle is*, not *how each phase executes* — that is in the scripts and in `agents/forge-orchestrator.md`.

**Lazy prompt:** $ARGUMENTS

## Critical: where this skill must run

**Run this skill from the main Claude Code session.** Do NOT run it from inside a spawned subagent. Spawned subagents lack the `Task` tool, which the forge-orchestrator depends on for dispatching parallel reviewers. If invoked from a context without `Task`:

1. Stop immediately.
2. Tell the user: "code-forge requires the Task tool — run /forge from the top-level session."
3. Do not try to simulate the cycle. The whole point is independent reviewer dispatch.

## What's new in v2

- **TDD as a first-class cycle phase.** Old cycle: `contract → implementation → evaluation`. New cycle: `contract → test-list → red → green → consolidated-review`. The test-author agent writes tests *before* the implementer touches code. forge-guard rule 5 blocks the implementer from editing test files during green — anti-weakening.
- **Script-coordinated parallel review.** The single evaluator is replaced by N reviewers (default 6) fanning out across dimensions — `correctness, design, error-handling, simplicity, tests-vs-impl, security`. A consolidator synthesizes their findings via `cycle-consolidate.mjs`. Pattern adopted from `~/.claude/sui-pilot/skills/move-pr-review/`.
- **Quality gates as code.** Phase advancement requires script-passing, not agent narration. `cycle-validate.sh`, `cycle-coverage.sh`, `cycle-pass.sh`, `cycle-tests-pass.sh` (with red-phase exit-code inversion).
- **forge-guard hooks extended.** Five new rules around TDD discipline, parallel reviewer fan-out, post-cycle freeze, and auto-validation on schema artifact edits. See `hooks/forge-guard.mjs`.
- **Thin orchestrator.** The four v1 orchestrators (preparation, planning, cycle, final-review) are compressed into one `forge-orchestrator` that drives the cycle by invoking scripts.

## Pre-cycle phases (carried forward from v1)

These phases run once before the per-cycle work begins. Codex cross-check gates (G1, G2) remain in place; forge-guard advisories still fire.

1. **Intent sharpening (Phase 0)** — Clarify the lazy prompt with the user. Output: `.forge/intent.md`.
2. **Codebase exploration (Phase 0.5, optional)** — Skip if greenfield. Dispatch the `codebase-explorer` agent (1–3 in parallel) to index the existing repo. Output: `.forge/codebase-analysis.md`.
3. **Prompt refinement (Phase 1)** — Iterate the planning prompt with Codex (G1). Output: `.forge/planning-prompt.md` + `.forge/prompt-evolution.md`.
4. **Agent detection (Phase 1.5, optional)** — Detect domain-specific subagents. Output: `.forge/agent-config.md`.
5. **Specification (Phase 2)** — Dispatch the `planner` agent. Output: `.forge/spec.md`.
6. **Spec critique (Phase 2.5)** — Codex critiques the spec (G2). Output: `.forge/spec-critique.md`.
7. **Cycle planning (Phase 3)** — Break the spec into ordered cycles. Output: `.forge/cycle-plan.md`.

After Phase 3, the forge-orchestrator agent takes over and drives the per-cycle loop.

## Per-cycle phases (the v2 loop)

For each cycle in `cycle-plan.md`:

| Phase | Owner | Artifact | Gate |
|---|---|---|---|
| `contract` | `planner` | `cycles/N/contract.md` | `cycle-validate.sh` ✓ + Codex G5 (optional) |
| `test-list` | `test-author` | `cycles/N/tests.json` | `cycle-validate.sh` ✓ + orchestrator review |
| `red` | `test-author` | `cycles/N/red.log` + `red.json` | `cycle-tests-pass.sh red` exit 0 (= tests fail correctly) |
| `green` | `implementer` | `cycles/N/green.log` + `green.json` | `cycle-tests-pass.sh green` exit 0 (= tests pass) + `forge-guard rule 5` (no test-file edits) |
| `consolidated-review` | `reviewer` ×N + `consolidator` | `cycles/N/_consolidated.json` + `cycles/N/review.md` | `cycle-pass.sh` exit 0 (no critical, no disputed) + Codex G5 (optional) |

**Single-turn dispatch is load-bearing for `consolidated-review`.** All N reviewers must be dispatched in one assistant message via N parallel `Agent` tool calls with `run_in_background: true`. Serial dispatch loses parallelism *and* independence (later reviewers can recall earlier outputs from context). forge-guard rule 6 enforces this — it blocks a second `reviewer` Agent call if a previous reviewer's output appeared >5 seconds ago.

## Final review

After the last cycle in the plan completes, the forge-orchestrator runs a final pass: invoke the consolidated-review pipeline against the entire deliverable (not just the last cycle's contract scope). Output: `.forge/final-review.md`. Codex G6 cross-check on the final artifact.

## Scripts (the protocol made executable)

All scripts in `${CLAUDE_PLUGIN_ROOT}/scripts/`:

| Script | Use |
|---|---|
| `cycle-init.sh <cycle-dir>` | Scaffold a cycle directory with empty schema-valid stubs. Run at the start of each cycle. |
| `cycle-validate.sh <path>` | Validate cycle artifacts (contract.md, tests.json, subagent-*.json) against schema. |
| `cycle-tests-pass.sh red\|green <cycle-dir> -- <test-cmd>` | Run the project's test command, write red.log/green.log + JSON metadata, INVERT exit code for red phase. |
| `cycle-coverage.sh <reviewers-dir>` | File × reviewer coverage matrix; flag files below floor (default 3 of 6) for R0 leader backfill. |
| `cycle-consolidate.mjs <reviewers-dir>` | Cluster reviewer findings, emit `_consolidated.json`. |
| `cycle-pass.sh <cycle-dir>` | Read `_consolidated.json`; exit 0 iff no critical AND no disputed clusters. The cycle-pass gate. |
| `forge-status.sh [<forge-dir>]` | Human-readable progress dashboard. User can run anytime. |

The skill file does NOT paraphrase what these scripts do. The scripts are the protocol.

## State

`.forge/state.json` is the source of truth for the cycle state machine. The forge-orchestrator updates it before every phase transition. forge-guard reads it for invariant checking. Schema in `agents/forge-orchestrator.md`.

## Hook discipline (forge-guard)

`hooks/forge-guard.mjs` codifies the protocol invariants:

**Blocking rules (exit code 2 — tool call rejected):**
- No implementation without contract (carried from rig)
- No advancing past a failed cycle review (extended in v2 to use `_consolidated.json`)
- Test-file edit block during green phase (v2 rule 5)
- Parallel reviewer fan-out enforcement (v2 rule 6) — blocks serial dispatch
- Post-cycle freeze on contract files (v2 rule 7)

**Advisory rules (exit 0, message to stderr — does NOT block):**
- Phase ordering / prerequisite-artifact checks (carried from rig)
- Codex gate artifacts present (carried from rig; respects `--light` mode)
- Auto-validate on schema artifact edits (v2 rule 8)

If you see `[BLOCK] Forge Guard:` the tool call has been rejected — fix the underlying issue, do not paper over it. If you see `[ADVISE] Forge Guard:` you should investigate; the call still went through.

## Smoke-testing the plugin itself

`/forge-smoke` runs `tests/smoke.sh` — the v2 plugin's self-test against fixtures under `tests/fixtures/`. CI also runs it on every push (see `.github/workflows/forge-smoke.yml` in the dotfiles repo). Run before pushing changes; CI catches breakage at merge boundary.

## Resume / status

If `.forge/state.json` exists in cwd when `/forge` is invoked, the forge-orchestrator resumes from the recorded phase. To inspect a partial run without resuming, run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/forge-status.sh`.

## Hand-off to forge-orchestrator

After parsing flags from `$ARGUMENTS` and creating `.forge/state.json` for a fresh run:

1. Initialize `.forge/state.json` with the parsed flags and `phase: "intent"`.
2. Dispatch the **forge-orchestrator** agent with the lazy prompt and the path to `.forge/`.
3. The forge-orchestrator runs the seven pre-cycle phases, then loops cycles until done.
4. When `.forge/state.json` reports `phase: "done"`, surface the final review path to the user.

That's the protocol. The scripts and forge-orchestrator carry the rest.
