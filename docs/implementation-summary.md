# Code-Forge v2 — Implementation Summary

Date: 2026-04-25

All five implementation phases complete. Plugin lives at `~/workspace/dotfiles/.claude/plugins/code-forge-v2/`. 29 files, 180 KB. Smoke test 19/19 green. Codex cross-checked.

## Where the spec was followed

| Spec section | What landed | Where |
|---|---|---|
| §3 (foundation) | Forked `code-forge-rig` 1.0.0 → `code-forge-v2` 0.1.0 | `.claude-plugin/plugin.json` |
| §4.1 (thin orchestrator) | 4 orchestrator agents → 1 `forge-orchestrator.md` | `agents/forge-orchestrator.md` |
| §4.2 (TDD-as-phase) | New cycle: contract → test-list → red → green → consolidated-review | `agents/test-author.md` + cycle scripts |
| §4.3 (script coordination) | `validate_schema.sh`/`consolidate.js`/`coverage_matrix.sh` ported to forge categories | `scripts/cycle-{validate,consolidate,coverage}.{sh,mjs}` |
| §4.4 (coverage backfill) | floor=3 of 6, R0 leader fill | `scripts/cycle-coverage.sh` |
| §4.5 (gates as code) | Phase advancement uses script exit codes, not agent narration | All `cycle-*.sh` scripts |
| §5 (agents) | 7 stable agent files: forge-orchestrator, planner, codebase-explorer, test-author, implementer, reviewer, consolidator | `agents/` |
| §5 (dimensions) | 6 reviewer dimensions: correctness, design, error-handling, simplicity, tests-vs-impl, security | `agents/reviewer.md` |
| §6 (artifact tree) | `cycles/N/{contract,tests,red,green,reviewers/,_consolidated,review}` | Codified in scripts + `cycle-init.sh` |
| §7 (schemas) | Reviewer findings, cluster, tests.json schemas with strict jq validators | `scripts/cycle-validate.sh` |
| §8 (hooks) | All 5 v2 rules implemented; rules 1/2/3/4 blocking, rule 5 advisory; rule 2 (red-phase exit code) lives in `cycle-tests-pass.sh` not the hook | `hooks/forge-guard.mjs` |
| §9 (scripts) | 7 scripts including `cycle-init.sh` (now auto-derives `_scope_files.txt` from contract) and `forge-status.sh` | `scripts/` |
| §10.5 (smoke gate) | CI workflow + `/forge-smoke` slash command, NO SessionStart hook | `tests/smoke.sh` + `commands/forge-smoke.md` + `.github/workflows/forge-smoke.yml` |

## Codex cross-check pass

After initial implementation, Codex reviewed the SKILL + spec + scripts and flagged three issues. All three fixed in this session:

| Codex finding | Resolution |
|---|---|
| **Hook enforcement overclaimed** — SKILL.md said phase ordering and Codex gates were enforced; `forge-guard.mjs` had those checks commented out as "Skip for now". | Re-enabled `checkPhaseTransitionV2` and `checkCodexGatesV2` (advisory, fire on `state.json`/`status.md` writes); updated SKILL.md to honestly distinguish blocking vs advisory rules. |
| **`_scope_files.txt` not derived from contract** — `cycle-coverage.sh` reads it but `cycle-init.sh` only created an empty stub. | `cycle-init.sh` now parses contract.md's `## Files` section with awk and writes the bullet paths to `_scope_files.txt`. Verified on the cycle-good fixture (4 files derived). |
| **Implementer prompt was v1 cruft** — still said "write tests, commit, produce implementation-notes.md". | Rewrote `agents/implementer.md` for v2: explicitly does NOT write tests, does NOT commit, does NOT produce implementation-notes.md. Output is source diffs + green.log/green.json. |

## Smoke test breakdown (19 assertions, all passing)

```
Section 0: Environment       — jq + node present
Section 1: cycle-validate.sh — accepts good fixture, rejects bad-tests-schema
Section 2: cycle-consolidate — runs, writes file, expected cluster count
Section 3: cycle-coverage    — runs on good fixture
Section 4: cycle-pass        — passes good, fails disputed fixture
Section 5: cycle-tests-pass  — red-phase inversion verified for all 4 quadrants
Section 6: cycle-init        — scaffolds correctly
Section 7: forge-status      — emits header (smoke-only, no semantic check)
```

## What's NOT yet done in this session

| Item | Why deferred | Effort to complete |
|---|---|---|
| **Three-way bench** (original / rig / v2 head-to-head) | `forge-bench.sh` hardcodes original/rig — doesn't accept a third variant. Adding v2 needs a script change AND ~30+ min of wall time per round. | Modify `forge-bench.sh` (or write `forge-bench3.sh`) to accept `--variants` list. Then run on the round-1 counter prompt + at least one extension prompt. ~1-2 hours including the runs. |
| **Enable `code-forge-v2` in user settings** | Modifying `~/.claude/settings.json` should be your call. The plugin is at the canonical path; it just needs `"code-forge-v2@local": true` (or your usual idiom) in `enabledPlugins`. | Manual edit of `~/.claude/settings.json`. |
| **Commit and push the dotclaude submodule** | I never commit unless asked. The new files are uncommitted in `~/workspace/dotfiles/.claude/`. | `cd ~/workspace/dotfiles/.claude && git add plugins/code-forge-v2 .github && git commit && git push`. |
| **Real-cycle dogfood** | Bench measures protocol adherence; real use measures whether the new agents produce good code. | Run `/forge` on a real small task (e.g. "add a TS helper that parses semver") with v2 enabled. Observe the artifact tree. |

## Open questions surfaced during implementation (worth revisiting)

- The `state.json` v2 format vs `status.md` (rig) frontmatter coexistence: `forge-guard.mjs` reads both but the orchestrator prompt only writes `state.json`. Spec is consistent; verify on first real run that state.json is actually written.
- `REVIEWERS=6` and `floor=3` are guesses. Tune after 3 real cycles per the spec's §11.2 rule (median agreement_count target [2,3]).
- The "5-second window" in `checkParallelReviewerFanout` is a heuristic. May produce false positives on slow networks. Tune empirically.
- `cycle-tests-pass.sh red` requires the test command to actually run the tests (not import-error early). Smoke verifies the inversion logic works; doesn't guarantee real test runners produce meaningful failures at red. Will be apparent on first real cycle.

## Files added/modified

```
~/workspace/dotfiles/.claude/plugins/code-forge-v2/
├── .claude-plugin/plugin.json         (modified — name, agents list)
├── agents/                            (rewritten)
│   ├── codebase-explorer.md           (unchanged from rig)
│   ├── consolidator.md                NEW
│   ├── forge-orchestrator.md          NEW
│   ├── implementer.md                 (rewritten for v2)
│   ├── planner.md                     (unchanged from rig)
│   ├── reviewer.md                    NEW (renamed from evaluator)
│   └── test-author.md                 NEW
├── commands/
│   ├── forge.md                       (description updated)
│   └── forge-smoke.md                 NEW
├── hooks/
│   ├── forge-guard.mjs                (extended: 4 new rules + adapted v1 checks)
│   └── hooks.json                     (matcher extended to Task|Agent)
├── scripts/                           ALL NEW
│   ├── cycle-consolidate.mjs
│   ├── cycle-coverage.sh
│   ├── cycle-init.sh
│   ├── cycle-pass.sh
│   ├── cycle-tests-pass.sh
│   ├── cycle-validate.sh
│   └── forge-status.sh
├── skills/code-forge/SKILL.md         (rewritten — high-level, not procedural)
└── tests/                             ALL NEW
    ├── smoke.sh
    └── fixtures/
        ├── cycle-good/                (contract + 3 reviewer JSONs + tests.json + scope)
        └── cycle-bad-tests-schema/    (broken tests.json for rejection assertion)

~/workspace/dotfiles/.claude/.github/
└── workflows/forge-smoke.yml          NEW
```

## Recommended next steps (in order)

1. **Review the spec + summary together** to confirm everything below is what you wanted: the new cycle order, the 6 reviewer dimensions, the post-cycle freeze rule, the smoke-gate architecture.
2. **Enable `code-forge-v2` in your `enabledPlugins` settings.**
3. **Commit and push the dotclaude submodule.** CI runs `tests/smoke.sh` on the push.
4. **Real-cycle dogfood:** run `/forge` on a small task with v2 enabled. Observe the artifact tree.
5. **Three-way bench:** modify `forge-bench.sh` to accept a third variant; rerun on round-1 counter prompt; compare original/rig/v2.
6. **Tune REVIEWERS and floor** based on real-cycle agreement_count distributions per spec §11.2.
