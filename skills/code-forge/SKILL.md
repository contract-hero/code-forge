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
version: 0.2.0
---

# Code Forge v2 — Cycle Protocol

You are the orchestrator of Code Forge v2. Your job is to **dispatch the forge-orchestrator agent** and let it drive the cycle by invoking scripts. The protocol is encoded in `${CLAUDE_PLUGIN_ROOT}/scripts/`. This file describes *what the cycle is*, not *how each phase executes* — that is in the scripts and in `agents/forge-orchestrator.md`.

**Lazy prompt:** $ARGUMENTS

## Critical: where this skill must run

**Run this skill from the main Claude Code session.** Do NOT run it from inside a spawned subagent. Spawned subagents lack the `Task` tool, which the forge-orchestrator depends on for dispatching parallel reviewers. If invoked from a context without `Task`:

1. Stop immediately.
2. Tell the user: "code-forge requires the Task tool — run /forge from the top-level session."
3. Do not try to simulate the cycle. The whole point is independent reviewer dispatch.

## What's new in v2 (and what v0.2.0 adds)

**v0.1.0 baseline:**
- **TDD as a first-class cycle phase.** Old cycle: `contract → implementation → evaluation`. New cycle: `contract → test-list → red → green → consolidated-review`. The test-author agent writes tests *before* the implementer touches code. forge-guard rule 5 blocks the implementer from editing test files during green — anti-weakening.
- **Script-coordinated parallel review.** The single evaluator is replaced by N reviewers (default 6) fanning out across dimensions — `correctness, design, error-handling, simplicity, tests-vs-impl, security`. A consolidator synthesizes their findings via `cycle-consolidate.mjs`. Pattern adopted from `~/.claude/sui-pilot/skills/move-pr-review/`.
- **Quality gates as code.** Phase advancement requires script-passing, not agent narration.
- **Thin orchestrator.** The four v1 orchestrators (preparation, planning, cycle, final-review) are compressed into one `forge-orchestrator` that drives the cycle by invoking scripts.

**v0.2.0 amendments (this version):**
- **Codex-mediated Phase 0 (claudex).** The pre-cycle compresses from 7 phases to 3. Phase 0 wraps the `codex-bridge:claudex` skill — multi-round Claude↔Codex refinement plus plan-mode AskUserQuestion clarification — and lands `plan.md`. `--quick` flag skips Phase 0 for trivial tasks.
- **E2E tests as cross-cycle invariant (Phase F).** spec.md gains a `## E2E Tests` section. After all cycles pass, Phase F dispatches reviewers ×N over scenarios with `MODE=e2e`; `cycle-e2e-pass.sh` gates ship; failures spawn a remediation cycle (cap = 3).
- **Best-of-N implementer (green phase).** 1 Opus coordinator + N=6 Sonnet workers (env `IMPLEMENTERS`). Each worker emits an independent candidate; coordinator runs each against tests, picks the simplest passer, writes `synthesis-notes.md`. forge-guard rule 7 blocks serial worker dispatch.
- **Specialist routing + project_domains.** Phase 1 emits `agent-config.md` with three blocks: `project_domains` (top-level tags like `sui-dapp` — when present, force sui-pilot for ALL Task dispatches via prompt injection), `required_subagents` (glob-based hard routing), `recommended_agents` (soft roster favoring the user's enabled plugins). forge-guard rule 6 hard-blocks subagent_type mismatches.

## Pre-cycle phases (compressed in v0.2.0: 7 → 3)

| Phase | Owner | Artifact | Codex gates |
|---|---|---|---|
| **0 — Plan** | forge-orchestrator (wraps `codex-bridge:claudex`) | `.forge/plan.md` | G1 (intrinsic to claudex's multi-round flow) |
| **1 — Spec & e2e** | `planner` in `spec-and-e2e` mode | `.forge/spec.md` (with `## E2E Tests`), `.forge/agent-config.md` | G2.a (plan↔spec), G2.b (spec↔e2e), each capped at 3 iterations |
| **2 — Cycle plan** | `planner` in `cycle-plan` mode | `.forge/cycle-plan.md` | G2.5 (cycle plan vs spec) |

For extension prompts, the codebase-explorer is dispatched from inside the Phase 0 plan-mode flow rather than as a separate phase. After Phase 2, the forge-orchestrator enters the per-cycle loop.

`--quick` flag (passed via `/forge`'s args) skips Phase 0; the lazy prompt becomes `plan.md` verbatim.

## Per-cycle phases (the v2 loop)

For each cycle in `cycle-plan.md`:

| Phase | Owner | Artifact | Gate |
|---|---|---|---|
| `contract` | `planner` (contract mode) | `cycles/N/contract.md` | `cycle-validate.sh` ✓ + Codex G5 (optional) |
| `test-list` | `test-author` | `cycles/N/tests.json` | `cycle-validate.sh` ✓ + orchestrator review |
| `red` | `test-author` | `cycles/N/red.log` + `red.json` | `cycle-tests-pass.sh red` exit 0 (= tests fail correctly) |
| `green` (best-of-N) | `implementer` (Opus coordinator) + N=6 `implementer-worker`s (Sonnet) | `cycles/N/green/candidates/worker-K/`, `synthesis-notes.md`, `green.log` | `cycle-tests-pass.sh green` exit 0 against the chosen candidate + forge-guard rules 5/7/8 (no test-file edits across 1+N family; no serial worker dispatch) |
| `consolidated-review` | `reviewer` ×N + `consolidator` | `cycles/N/_consolidated.json` + `cycles/N/review.md` | `cycle-pass.sh` exit 0 (no critical, no disputed) + Codex G5 (optional) |

**Single-turn dispatch is load-bearing** for both `green` (worker fan-out) and `consolidated-review` (reviewer fan-out). All workers / reviewers must be dispatched in one assistant message via parallel `Agent` tool calls with `run_in_background: true`. Serial dispatch loses parallelism *and* independence. forge-guard rules 3 and 7 enforce this.

## Post-cycle: Phase F — e2e-review

Triggered after the last cycle's `consolidated-review` passes, when `spec.md` contains a `## E2E Tests` section.

| Step | Owner | Artifact | Gate |
|---|---|---|---|
| Extract scenarios | `e2e-extract.sh` | `.forge/e2e/scenarios.json` | `cycle-validate.sh` ✓ |
| Review scenarios | `reviewer` ×N (`MODE=e2e`) — Chrome MCP for `kind: ui`, harness for `cli`/`api` | `.forge/e2e/reviewers/subagent-K.json` | `cycle-validate.sh` ✓ |
| Consolidate | `consolidator` (`MODE=e2e`) | `.forge/e2e/_consolidated.json`, `.forge/e2e/review.md` | `cycle-e2e-pass.sh` exit 0 (no critical, every scenario covered) |

If `cycle-e2e-pass.sh` fails, a **remediation cycle** is spawned (`cycles/N+1/`) with a contract derived from the e2e gaps. Cap = 3 remediation cycles before escalating to the user.

If `spec.md` has no `## E2E Tests` section, Phase F is skipped. forge-guard advises at Phase 1 exit when cycle-plan has >1 cycle and no e2e tests are declared.

## Scripts (the protocol made executable)

All scripts in `${CLAUDE_PLUGIN_ROOT}/scripts/`:

| Script | Use |
|---|---|
| `cycle-init.sh <cycle-dir>` | Scaffold a cycle directory with empty schema-valid stubs. Run at the start of each cycle. |
| `cycle-validate.sh <path>` | Validate cycle artifacts (plan.md, spec.md, agent-config.md, cycle-plan.md, contract.md, tests.json, scenarios.json, subagent-*.json) against schema. |
| `cycle-tests-pass.sh red\|green <cycle-dir> -- <test-cmd>` | Run the project's test command, write red.log/green.log + JSON metadata, INVERT exit code for red phase. |
| `cycle-coverage.sh <reviewers-dir>` | File × reviewer coverage matrix; flag files below floor (default 3 of 6) for R0 leader backfill. |
| `cycle-consolidate.mjs <reviewers-dir>` | Cluster reviewer findings, emit `_consolidated.json`. |
| `cycle-pass.sh <cycle-dir>` | Read `_consolidated.json`; exit 0 iff no critical AND no disputed clusters. The cycle-pass gate. |
| `e2e-extract.sh <spec.md> <out-scenarios.json>` | Parse `## E2E Tests` from spec.md into `scenarios.json` for Phase F. |
| `cycle-e2e-pass.sh <e2e-dir>` | Read `e2e/_consolidated.json` + `e2e/scenarios.json`; exit 0 iff no critical AND every scenario has at least one passing reviewer touch. The ship gate. |
| `forge-status.sh [<forge-dir>]` | Human-readable progress dashboard. User can run anytime. |
| `deploy.sh [--dry-run\|--check]` | Sync the repo's plugin tree to `~/.claude/plugins/code-forge-v2/`. Run after committing changes. |

The skill file does NOT paraphrase what these scripts do. The scripts are the protocol.

## State

`.forge/state.json` is the source of truth for the cycle state machine. The forge-orchestrator updates it before every phase transition. forge-guard reads it for invariant checking. Schema in `agents/forge-orchestrator.md`.

## Hook discipline (forge-guard)

`hooks/forge-guard.mjs` codifies the protocol invariants. Each invariant maps to a function in the hook; the spec's §8 rule numbers and the hook's internal rule numbers were offset by four in v0.1.0 (the rig kept its original 1–4 numbering and v2 numbered the new rules 5–8 sequentially). The list below describes behavior; the function name is the source of truth.

**Blocking rules (exit code 2 — tool call rejected):**
- `checkContractExists` — no implementation without a contract (carried from rig).
- `checkPreviousCyclePassed` — no advancing past a failed cycle review (uses `_consolidated.json` in v2).
- `checkTestFileEditDuringGreen` — during green phase, blocks edits to paths listed in `tests.json`'s `target_file` entries. Agent-blind (applies to the implementer coordinator AND every implementer-worker; the "extends to all 11 agents" claim in spec §0.C is satisfied without code changes).
- `checkParallelReviewerFanout` — during `consolidated-review`, blocks a second `reviewer` Task dispatch after another reviewer's `subagent-N.json` has been live for >5s.
- `checkPostCycleFreeze` — once a cycle's `_consolidated.json` is sealed, blocks edits to files named in that cycle's `contract.md` until the next cycle's `contract` phase.
- `checkSpecialistRouting` (v0.2.0) — reads `agent-config.md`. If `project_domains` contains a sui-ecosystem domain (`sui-dapp`, `walrus`, `seal`, `sui-cli`), every Task dispatch must use `subagent_type="sui-pilot:sui-pilot-agent"`. Otherwise enforces `required_subagents[*].match` globs scoped by `applies_to`.
- `checkWorkerFanout` (v0.2.0) — during green phase, blocks a second `implementer-worker` Task dispatch after another worker's candidate directory already exists.

**Advisory rules (exit 0, message to stderr — does NOT block):**
- `checkPhaseTransitionV2` — phase ordering / prerequisite-artifact warnings on `state.json` writes (carried from rig).
- `checkCodexGatesV2` — Codex-gate artifact presence at planning gates (respects `--light` mode).
- `fireValidateOnSchemaArtifact` — fires `cycle-validate.sh` on edits to schema-bearing files (`tests.json`, `contract.md`, `subagent-*.json`, `agent-config.md`, `scenarios.json`, etc.).

If you see `[BLOCK] Forge Guard:` the tool call has been rejected — fix the underlying issue, do not paper over it. If you see `[ADVISE] Forge Guard:` you should investigate; the call still went through.

## Smoke-testing the plugin itself

`/forge-smoke` runs `tests/smoke.sh` — the v2 plugin's self-test against fixtures under `tests/fixtures/`. CI also runs it on every push (see `.github/workflows/forge-smoke.yml` in the dotfiles repo). Run before pushing changes; CI catches breakage at merge boundary.

## Resume / status

If `.forge/state.json` exists in cwd when `/forge` is invoked, the forge-orchestrator resumes from the recorded phase. To inspect a partial run without resuming, run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/forge-status.sh`.

## Hand-off to forge-orchestrator

After parsing flags from `$ARGUMENTS` and creating `.forge/state.json` for a fresh run:

1. Initialize `.forge/state.json` with the parsed flags and `phase: "plan"` (or `phase: "spec-and-e2e"` if `--quick`).
2. Dispatch the **forge-orchestrator** agent with the lazy prompt and the path to `.forge/`.
3. The forge-orchestrator runs Phase 0 → Phase 1 → Phase 2, then loops cycles, then runs Phase F (if applicable).
4. When `.forge/state.json` reports `phase: "done"`, surface the final review path to the user.

That's the protocol. The scripts and forge-orchestrator carry the rest.
