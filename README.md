# code-forge

A multi-agent build system that turns lazy prompts into shippable software through structured planning, TDD-as-phase, parallel review, and hook-enforced protocol discipline.

> Status: **v0.1.0 — fresh-start release of the renamed plugin (formerly `code-forge-v2`).** Smoke 19/19 green. The plugin loads from a submodule at `~/.claude/code-forge/` (mirroring the sui-pilot submodule pattern). Run `bash scripts/deploy.sh` to push working-tree changes to the live install. See [`docs/implementation-summary.md`](./docs/implementation-summary.md) and [`spec.md`](./spec.md) for design history.

## Start here: open the playground

[`playground.html`](./playground.html) is an interactive architecture explorer. Open it locally:

```bash
open playground.html
```

Lanes for pre-cycle phases / per-cycle phases / post-cycle (e2e) / agents / scripts / hooks. Click any node for inputs, outputs, constraints. Switch between curated preset views (TDD path, Best-of-N green, Phase F e2e, Reviewer fan-out, Hook discipline). Comments roll into a copyable prompt for follow-up Q&A.

If you spend 5 minutes there, you'll understand more than any README could tell you.

## Then read the spec

[`spec.md`](./spec.md) is the v0.2.0 design document — ~880 lines, structured. Highlights:

- §0 — v0.2.0 amendments summary (5 design changes from v0.1.0).
- §4 — architectural shifts: thin orchestrator, TDD-as-phase, script-coordinated review, best-of-N implementer, project-domain compound routing, e2e as cross-cycle invariant.
- §5 — agent hierarchy.
- §7 — JSON schemas for findings, clusters, tests, e2e scenarios, agent-config.
- §8 — forge-guard hook rules.

## What's implemented vs designed

| Phase | Status | Lives at |
|---|---|---|
| TDD-as-phase, parallel review, gates as code, smoke tests | **shipped, smoke 19/19 green** | this repo (plugin tree at root); deploys to `~/.claude/code-forge/` |
| claudex Phase 0, e2e-as-glue, best-of-N implementer, project-domain routing | **shipped in this release** | this repo, see [`spec.md`](./spec.md) |

See [`docs/implementation-summary.md`](./docs/implementation-summary.md) for what was actually built in v0.1.0 and how it was verified.

## Why this exists

Multi-agent code generation has the same three failure modes everywhere: agents drift on protocol over long sessions, individual reviewer agents share blind spots, and "the test suite passed" turns out to mean "the test suite that was written specifically to pass." code-forge addresses each one mechanically:

- **Protocol drift** → `forge-guard.mjs` blocking hooks (5 rules in v0.1.0; 8 rules in v0.2.0 design).
- **Reviewer blind spots** → script-coordinated parallel fan-out (×6 dimensional reviewers + R0 leader backfill, pattern adopted from [sui-pilot's move-pr-review](https://github.com/alilloig/sui-pilot)).
- **Tautological tests** → TDD-as-phase: a dedicated test-author writes tests *before* implementation, with `cycle-tests-pass.sh` inverting exit codes for the red phase to catch tests that pass at red.

The v0.2.0 design adds e2e tests as the cross-cycle invariant (Phase F, post-cycles), best-of-N implementer (1 Opus coordinator + 6 Sonnet workers, pick-best synthesis), and project-domain compound routing (`sui-dapp` → sui-pilot for every Task dispatch in the run).

## Layout

This repo is **both** the design home and the plugin source. The plugin tree lives at the repo root:

```
.
├── README.md                          # this file
├── PLUGIN.md                          # plugin user docs (commands, agents, schemas)
├── spec.md                            # v0.2.0 design spec
├── playground.html                    # interactive architecture explorer
│
├── .claude-plugin/plugin.json         # plugin manifest
├── agents/                            # forge-orchestrator, planner, implementer(+worker), test-author, reviewer, consolidator, codebase-explorer
├── commands/                          # /forge, /forge-smoke
├── hooks/                             # forge-guard.mjs (8 rules)
├── scripts/                           # cycle-* gates + deploy.sh + e2e-extract.sh
├── skills/code-forge/SKILL.md         # protocol overview
├── tests/                             # smoke.sh + fixtures
│
├── docs/
│   ├── implementation-summary.md      # v0.1.0 build report
│   ├── agent-routing.md               # agent dispatch rules + user preferences
│   └── initial-plan.md                # historical: v0.1.0 plan
└── bench/
    └── round-1-greenfield/            # forge-bench round-1 results that drove the v2 foundation pick
```

## Deploy to live install

The plugin source lives here; Claude Code loads from `~/.claude/code-forge/` (the dotclaude submodule pointing at this repo). Sync after changes:

```bash
bash scripts/deploy.sh             # rsync repo → install
bash scripts/deploy.sh --dry-run   # show what would change
bash scripts/deploy.sh --check     # exit 0 if in sync
```

## Related repos

- [`sui-pilot`](https://github.com/alilloig/sui-pilot) — the source of the script-coordinated parallel-review pattern (`move-pr-review` skill).
