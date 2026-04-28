---
name: forge-implementer
description: Procedure manual for Code Forge's green-phase coordinator. NOT a dispatchable subagent — the main session driving /forge reads this file directly when running each cycle's green (best-of-N) phase. Lists the 5-step protocol, scoring rubric, and synthesis-notes shape. Mirrors the F6 pattern that made forge-orchestrator a procedure manual.
tools: Read, Bash
model: opus
color: blue
---

This is a **procedure manual**, not a dispatchable subagent. The main Claude Code session driving `/forge` reads this file when running each cycle's green phase. Subagents in Claude Code lack the `Agent`/`Task` tool, so a spawned `forge-implementer` cannot fan out the 6 workers — it would degrade to best-of-1 silently. Same architectural class as F6's fix for `forge-orchestrator` (see `agents/forge-orchestrator.md`).

If you are reading this because you were dispatched as `code-forge:forge-implementer`: stop. Reply to your dispatcher with: "forge-implementer is a procedure manual, not a dispatchable agent. The main Claude Code session running /forge should read this file and drive the green phase itself; do not dispatch me." Don't try to drive the green phase; you don't have `Agent`.

If you are reading this because you are the main session driving /forge's per-cycle green phase: this manual describes the 5-step best-of-N protocol. Dispatch the workers yourself; you have `Agent`.

## Critical constraint: test files are read-only during green

forge-guard rule 5/8 blocks any Edit/Write to a path listed in `cycles/N/tests.json`'s `test_file` entries during green phase — for the main session AND every implementer-worker. The anti-weakening rule from spec §13. If a candidate's test run fails because the test is genuinely wrong, escalate **BLOCKED — tests need amendment** and roll back to the test-list phase; do not patch the test.

(F10 in v0.4.x extends this to Bash file-writes as well, via `checkBashFileWriteDuringGreen`. See `hooks/forge-guard.mjs`.)

## Inputs

- `cycles/N/contract.md` — what the cycle delivers
- `cycles/N/tests.json` — pruned test list
- `cycles/N/red.log` and `red.json` — proof of failing tests at red
- `IMPLEMENTERS` env var — N (default 6)
- The repo working tree (read; do not write to it until pick-best at step 5)

## The protocol — five steps, no creative interpretation

### Step 1 — Dispatch N workers in a SINGLE assistant turn

In ONE message, issue N parallel `Agent` Task calls with:
- `subagent_type: "code-forge:forge-implementer-worker"` (or whatever specialist `agent-config.md` mandates — forge-guard rule 6 will block mismatches; see Routing below)
- `run_in_background: true`
- `prompt: "<role-prompt + worker number K + cycle path>"`

Each worker is told its `K` (1..N) so it stages output under `cycles/N/green/candidates/worker-K/`. Single-turn dispatch is **load-bearing** — forge-guard rule 7 blocks any worker dispatched after another worker's `worker-K/` directory has appeared. Serial dispatch defeats the diversity-and-selection design.

### Step 2 — Wait for all workers

Wait until every worker's `cycles/N/green/candidates/worker-K/manifest.json` exists. If any worker reports `blocked: true`, note it but do not abort yet — collect the blocked-reason set; partial blocks are still useful diversity signal.

### Step 3 — Run each candidate against the test command

For each non-blocked worker `K`:

```bash
# Stage the candidate into a scratch worktree (or temporary copy)
WORK=$(mktemp -d)
rsync -a "${REPO_ROOT}/" "${WORK}/" --exclude .forge --exclude node_modules
rsync -a "${CANDIDATE_K}/files/" "${WORK}/"
# Run the project's test command against the candidate
bash ${CLAUDE_PLUGIN_ROOT}/scripts/cycle-tests-pass.sh green \
  ${CYCLE_DIR} \
  --repo-root "${WORK}" \
  -- <project-test-cmd>
```

Record the exit code in the candidate's `manifest.json` as `tests_pass: true|false`. Keep only passers.

### Step 4 — Pick the simplest passer

Score each passer (lower is simpler):
1. **Total LOC** across `target_file`s — read `lines_changed` from manifest.
2. **Number of files touched** — read `target_files.length`.
3. **Cyclomatic-complexity proxy** — count `if|for|while|case|catch|&&|\|\|` in changed files (cheap heuristic; tie-breaker only).

Pick the candidate with the lowest score. Ties broken by lowest worker number (deterministic).

If **no candidate passed**, write a no-passer report into `cycles/N/green/synthesis-notes.md` and re-dispatch a fresh batch of workers with feedback (cap = 3 retries per phase, tracked in `state.json.retries_per_phase.green`).

### Step 5 — Apply chosen candidate; write synthesis-notes.md; emit green.log

```bash
# Apply chosen candidate to the actual repo
rsync -a "${CANDIDATE_CHOSEN}/files/" "${REPO_ROOT}/"
# Final test run for the green.log artifact
bash ${CLAUDE_PLUGIN_ROOT}/scripts/cycle-tests-pass.sh green ${CYCLE_DIR} -- <project-test-cmd>
```

Write `cycles/N/green/synthesis-notes.md`:

```markdown
# Green-phase synthesis — cycle N

## Pick
worker-K — score=NN (LOC=A, files=B, complexity-proxy=C)

## Candidate scores
| Worker | Pass | LOC | Files | Complexity | Notes |
|---|---|---|---|---|---|
| 1 | yes | 87 | 2 | 12 | clean |
| 2 | no  | -  | -  | -  | tests/foo.spec.ts: missing assert on … |
| 3 | yes | 142 | 3 | 19 | extra utility helper not under test |
| 4 | yes | 78 | 2 | 9  | **chosen** |
| 5 | yes | 92 | 2 | 11 | nearly identical to worker-4 |
| 6 | blocked | - | - | - | "reason: contract ambiguous on X" |

## Diversity signal
Workers 1, 4, 5 converged on similar approaches (LOC within 20%); 3 took a
heavier path; 6 blocked. Diversity = medium. No "all-converged-on-wrong-answer"
red flag.
```

If diversity is **low** AND all workers passed (e.g. all 6 produced the same diff), flag explicitly: "Low diversity — likely shared blind spot." (Counter via prompt-seed mutation is deferred to v0.5.x; we just record the signal.)

## Routing

If `agent-config.md` declares a sui-ecosystem `project_domain` (e.g. `sui-dapp`), forge-guard rule 6 (post-F7 scope) forces source-touching role dispatches — including each implementer-worker — to use `subagent_type = "sui-pilot:sui-pilot-agent"`. In that case, embed the implementer-worker role prompt in the Task call's `prompt` field and use the specialist as `subagent_type`. The role behavior comes from the prompt; the subagent_type stays sui-pilot. See spec §4.7.2.

If no `project_domains`, fall back to per-glob `required_subagents`. Post-F12, the rule reads the cycle's `contract.md ## Files` to decide whether the binding fires; if a Move file is in scope and the binding requires sui-pilot, the workers must dispatch as sui-pilot.

If neither domain nor glob applies, dispatch with `subagent_type: "code-forge:forge-implementer-worker"`.

## What the main session does NOT do during green

- Do not write tests. The test-author's tests are read-only.
- Do not commit. Git operations happen after the cycle's `consolidated-review` passes.
- Do not write source files yourself except to fix trivial post-pick drift (e.g. moving a file to a different path the test expects). If you find yourself writing meaningful code, dispatch another worker instead.
- Do not loop forever — green-phase retries cap at 3 (per `state.json.retries_per_phase.green`).
- Do not "merge" multiple candidates. Pick-best is selection, not synthesis. Frankenstein-merging risks code no single worker produced.
- Do not edit any file in `test_file` of `tests.json`. forge-guard rule 5/8 will block Edit/Write; rule 10 (F10) will block Bash writes.

## Reporting

The green phase's outputs are:
1. The applied candidate's source diffs (visible to the orchestrator's review phase).
2. `cycles/N/green/synthesis-notes.md` — the pick-best record.
3. `cycles/N/green.log` and `green.json` — final test-runner output (the script writes these).
4. The candidates directory `cycles/N/green/candidates/worker-1..N/` is preserved for audit; do not delete.

If you must escalate (BLOCKED, NO_PASSER, NEEDS_CONTEXT), surface it in `synthesis-notes.md` and decide: re-dispatch a new batch (within retry cap) or roll back to test-list (if tests are wrong).
