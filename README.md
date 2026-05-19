# code-forge

A multi-agent build system that turns lazy prompts into shippable PoCs/MVPs through recursive `/goal` orchestration, TDD-as-phase, best-of-N workers, and configurable dimensional review.

> **Single source of truth — [alilloig.github.io/code-forge](https://alilloig.github.io/code-forge/)**
> The GitHub Pages landing is the easiest way to understand what Code Forge does:
> diagrams of the outer + per-cycle architecture, the dimension menu, the one
> surviving hook, and a quick-start. Source: [`docs/index.html`](./docs/index.html).
> Enable Pages in repo settings → Pages → Source: `main` branch / `/docs` folder.

> See [`docs/goal-integration.md`](./docs/goal-integration.md) for the full protocol and [`templates/spec.md.template`](./templates/spec.md.template) for the spec skeleton the planner fills in.

## Quick start

```bash
# Top-level launcher (or invoke /forge from inside Claude Code)
bash scripts/forge.sh "Build a CLI that counts source lines"

# Skip Phase 0 claudex refinement for trivial tasks
bash scripts/forge.sh "Add a --json flag to my CLI" --quick

# Skip the optional G2.5 Codex gate (cost savings)
bash scripts/forge.sh "<description>" --light
```

The launcher spawns the outer Claude session with this `/goal` active:

> *every cycle id in `.forge/spec.md ## Cycle Plan` has produced a corresponding `cycles/<id>/result.json` file containing `status: pass`, or stop after K outer turns*

That outer session reads the spec, picks the next pending cycle, spawns one `claude -p /goal` child per cycle, waits for each child's `result.json`, narrates the result so the evaluator can see it, and loops until done.

## Architecture (Option D)

Two nested goal sessions, joined at session boundaries — `/goal` is one-goal-per-session by design, but session boundaries sidestep the limit:

```
top:   claude -p "/goal <outer condition>"
         │
         ▼ (outer Claude reads spec, picks next cycle, spawns child)
cycle: claude -p "/goal <per-cycle condition>"
         │
         ▼ (cycle child: tests → red → 6 workers → score → reviewers → consolidate)
       result.json
```

## What gets preserved from earlier code-forge releases

- **Best-of-N implementer** (default N=6 Sonnet workers; single-turn parallel dispatch; pick simplest passer).
- **Dimensional reviewers**, now configurable per spec.md (`## Reviewer Config` defines model + dimensions; the dimensions list length IS the reviewer count).
- **Consolidator** (clusters findings inline, verifies critical/high against source, writes `review.md`).
- **Codex gates** (G2.a / G2.b / G2.5 in planner — still cross-AI second-opinion gates).
- **Test immutability** (forge-guard rule 5 — the one surviving hook).

## What dropped in Option D

- 7 of 8 forge-guard rules (only rule 5 / test immutability survives).
- `cycle-pass.sh`, `cycle-coverage.sh`, `cycle-e2e-pass.sh`, `cycle-consolidate.mjs`, `e2e-extract.sh` — five gate/utility scripts replaced by `result.json` + inline consolidation.
- `forge-orchestrator.md` + `implementer.md` procedure manuals — replaced by the cycle child's inline procedure in `docs/goal-integration.md`.
- `contract.md` per cycle — folded into the cycle plan entry's `files_affected` + `acceptance` fields inside `spec.md`.
- Phase F (e2e remediation cycles) — e2e tests are baked into the final cycle's `tests.json`.

Net delta vs v0.1.0: roughly **-450 to -650 lines**.

## Why Option D

Three failure modes of multi-agent code generation:

- **Protocol drift** — agents skip phases or bypass gates over long sessions. The cycle child's `/goal` condition replaces 7 forge-guard hooks: the child cannot exit without producing `result.json status: pass`.
- **Reviewer blind spots** — single reviewer misses things. Dimensional fan-out kept and made configurable.
- **Tautological tests** — tests that pass at red phase aren't testing anything. Both the red-gate (inverted exit code) and rule 5 (test immutability during green) survive.

## Layout

```
.
├── README.md
├── .claude-plugin/plugin.json
├── commands/
│   ├── forge.md            # /forge — thin wrapper invoking the skill
│   └── forge-smoke.md      # /forge-smoke — runs tests/smoke.sh
├── agents/
│   ├── planner.md          # Phase 1 spec author (incl. Phase 1.5 Reviewer Config sub-step)
│   ├── codebase-explorer.md
│   ├── test-author.md
│   ├── implementer-worker.md
│   ├── reviewer.md         # generic dimensional reviewer (parameterized by prompt)
│   └── consolidator.md     # inline clustering + verification + review.md
├── hooks/
│   ├── hooks.json          # PreToolUse(Write|Edit|Bash) only
│   └── forge-guard.mjs     # rule 5 only (test immutability)
├── scripts/
│   ├── forge.sh            # top-level launcher (spawns the outer /goal)
│   ├── cycle-init.sh
│   ├── cycle-validate.sh
│   ├── cycle-tests-pass.sh # red/green truth gate (inverts at red)
│   ├── forge-status.sh
│   └── deploy.sh
├── skills/code-forge/SKILL.md
├── templates/spec.md.template
├── docs/
│   ├── goal-integration.md  # the Option D protocol (outer + cycle child)
│   ├── implementation-summary.md
│   └── v0.2.0-build-report.md
└── tests/
    ├── smoke.sh
    └── fixtures/
```

## Hook discipline (one rule survives)

`hooks/forge-guard.mjs` blocks Edit/Write/Bash writes to any path listed in `cycles/<id>/tests.json[*].test_file` during green phase. Without this, `/goal "tests pass"` would happily mutate tests instead of the implementation — the evaluator can't diff against a baseline.

| Former rule | Option D replacement |
|---|---|
| 1 — no impl without contract | Cycle plan entry IS the contract; cycle child enforces. |
| 2 — no advance past failed review | Outer goal condition checks `result.json status: pass`. |
| 3 — single-turn reviewer fan-out | Cycle child controls dispatch directly. |
| 4 — phase ordering advisory | Cycle child procedure defines the order. |
| **5 — tests read-only during green** | **Kept.** |
| 6 — specialist routing | spec.md / agent-config.md hints, voluntary. |
| 7 — single-turn worker fan-out | Cycle child controls dispatch directly. |
| 8 — schema auto-validate on artifact edits | Inline validation in cycle child. |

## Deploy to live install

The plugin source lives here; Claude Code loads from `~/.claude/code-forge/` (the dotclaude submodule pointing at this repo). Sync after changes:

```bash
bash scripts/deploy.sh             # rsync repo → install
bash scripts/deploy.sh --dry-run   # show what would change
bash scripts/deploy.sh --check     # exit 0 if in sync
```

## Related repos

- [`sui-pilot`](https://github.com/alilloig/sui-pilot) — the source of the script-coordinated parallel-review pattern (`move-pr-review` skill).
