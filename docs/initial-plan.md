# Initial v0.1.0 plan (historical)

This was the implementation plan that produced code-forge v2 0.1.0 (now shipped to `dotclaude/plugins/code-forge-v2/`). Preserved here for context — the *actual* spec is [`../spec.md`](../spec.md), which has been substantially extended with v0.2.0 amendments.

The plan as drafted on 2026-04-25:

---

# Code-Forge: Next Level

Take `code-forge` from a 1.0 multi-agent build system to a 2.0 with three structural changes:

1. Pick a foundation (original vs rig) on the basis of empirical bench data, not architectural taste.
2. Adopt the **script-coordinated parallel-agent pattern** that the new `move-pr-review` skill in `sui-pilot` validated this week.
3. Make **TDD a first-class cycle phase**, gated by a hook in the rig spirit.

## Context

`code-forge` and `code-forge-rig` are twin orchestrators in `~/workspace/dotfiles/.claude/plugins/`. They share the same eight agents and a single skill; the only on-disk difference is `code-forge-rig/hooks/forge-guard.mjs` (348 lines) — a `PreToolUse`/`PostToolUse` interceptor that codifies invariants like "no implementation before contract" and "no cycle advance before evaluator pass."

`forge-bench` exists to compare them but has produced no saved runs — there is no empirical answer yet to "which foundation is better."

Meanwhile, in `sui-pilot`, the `move-pr-review` skill (last touched today on `origin/main`, **9 commits ahead of local**) demonstrates a coordination pattern that is exactly what code-forge's cycle-orchestrator currently lacks: **shell + Node scripts that fan out parallel reviewer agents, validate their JSON outputs against a schema, cluster findings with agreement-and-coverage gates, and hand a single consolidated artifact to a downstream agent**. That pattern, generalized, fits forge cycles cleanly.

Independent of all that, the case for first-class TDD inside forge has gotten stronger: the `topics/05-tdd.md` chapter argues TDD's value with an LLM is no longer about design but about **installing an external truth signal the agent cannot fabricate**. Forge cycles already have an evaluator; they do not yet have *tests as the contract's executable form*.

The intended outcome is a code-forge 2.0 where:
- Each cycle's "done" verdict is anchored in tests written before implementation, not the implementer's narration.
- Multi-perspective review and consolidation inside each cycle uses the move-pr-review script-coordination pattern, not ad-hoc agent monologues.
- Protocol drift is prevented by code (forge-guard hooks), not by hoping agents read the skill file carefully.

## Phase 0 — Sync and bench (blocking work; no code yet)

- 0.1 Pull sui-pilot main (was 9 commits behind) so move-pr-review's smoke tests, REVIEWERS env var, and BSD/GNU portability fixes are in tree.
- 0.2 Run forge-bench at least twice — pick two prompts of distinct shape (greenfield + extension).
- 0.3 Read forge-compare reports. Document in `.forge-bench/decision-notes.md`.
- 0.4 Pick the foundation:
  - rig clearly/marginally better → fork rig
  - original better or no difference → fork original, port forge-guard.mjs separately
  - inconclusive → default to rig

## Phase 1 — Fork v2 and re-baseline

- Create `code-forge-v2/` from chosen foundation.
- Replace per-phase orchestrators with one thin orchestrator (decision in Phase 4).
- Move SKILL.md procedural logic into `scripts/`.

## Phase 2 — Adopt the move-pr-review coordination pattern

| Source script | v2 analog | Purpose |
|---|---|---|
| `validate_schema.sh` | `cycle-validate.sh` | jq schema check on each phase artifact |
| `consolidate.js` | `cycle-consolidate.mjs` | Cluster reviewer findings |
| `coverage_matrix.sh` | `cycle-coverage.sh` | File × reviewer matrix; flag for R0 backfill |
| `tests/smoke.sh` | `tests/smoke.sh` | CI gate against fixtures |

Patterns to encode: parallel dispatch with REVIEWERS env var, schema-validate before consolidate, coverage-driven backfill, foreground consolidation.

## Phase 3 — TDD as first-class cycle phase

New cycle: `contract → test-list → red → green → consolidated-review`.

- `test-list` — test-author emits `tests.json` (names + behaviors).
- `red` — test-author writes test code; runs suite. Hook rule rejects if tests pass at red.
- `green` — implementer writes code. Hook rule blocks edits to test files.
- `consolidated-review` — N parallel reviewers + consolidator.

## Phase 4 — Compress agent hierarchy 8→7+N

Collapse 4 orchestrators (preparation/planning/cycle/final-review) into one `forge-orchestrator`. Keep planner, codebase-explorer. Add test-author. Generalize evaluator → reviewer (dimension-parameterized). Add separate consolidator file.

## Phase 5 — Migration and validation

- Port the eight existing agent prompts into the new shape.
- Write `tests/smoke.sh` first (TDD on the plugin itself).
- Re-run forge-bench three-way (original / rig / v2).
- Codex cross-check the new SKILL.md and forge-guard.mjs.

## Verification

1. `bash tests/smoke.sh` exits 0.
2. `/forge-bench` v2 vs rig — verdict at least "marginally better."
3. End-to-end `/forge` run produces the new cycle phases in `.forge/`.
4. Codex cross-check passes on a sample artifact bundle.

---

## What actually happened (executed 2026-04-25)

All five phases shipped. Smoke test at 19/19 green. Codex cross-check caught three real gaps (hook enforcement overclaim, missing `_scope_files.txt` derivation, v1 cruft in implementer prompt) — all fixed. See [`implementation-summary.md`](./implementation-summary.md) for the build report.

The plan deliberately deferred the three-way bench (forge-bench.sh hardcodes original/rig and would need a script change to add a third variant). That deferral is still open.

This file is preserved for historical reference; the live design is in [`../spec.md`](../spec.md) which has been extended with v0.2.0 amendments.
