# `/goal` integration — narrative protocol

Code Forge orchestrates one build run as a `/forge` skill in the user's
interactive Claude Code session, which spawns one `claude -p /goal` per
cycle for the autonomous bits. This document is the procedure manual the
human + the skill read when driving the protocol.

```
/forge "task"
    │
    ▼ (skill runs in the user's Claude Code session)
Phase 0 (claudex) → Phase 1 (planner authors spec.md)
    │
    ▼ (skill loops over spec.md ## Cycle Plan)
spawn:  claude -p /goal "<per-cycle condition>"
    │
    ▼ (cycle child: tests → red → 6 workers → score → reviewers → consolidator)
    result.json
    │
    ▼ (skill reads, narrates "cycle X status=pass", continues)
```

`/goal` is one-goal-per-session. The cycle child's session boundary is
what gives each cycle its own `/goal` + Haiku evaluator; the skill itself
runs without `/goal` and drives the loop deterministically (the user can
intervene at any point — that's the design).

## Skill orchestrator (in your Claude Code session)

### Entry

The user invokes `/forge "task description" [--quick] [--light] [--resume]`.
The command loads `skills/code-forge/SKILL.md` into the current session;
that skill is the orchestrator.

### What the skill does

1. **Pre-flight**.
   - `claude --version` ≥ v2.1.139 (the per-cycle children depend on
     `/goal`).
   - Stale `.forge/state.json` check — `AskUserQuestion` for
     resume / wipe / abort unless `--resume` was passed.
   - `mkdir -p .forge/`.
2. **Phase 0 — Plan** (skip if `--quick`): invoke the
   `codex-bridge:claudex` skill on the lazy prompt. Land `.forge/plan.md`.
   `--quick` writes the lazy prompt verbatim.
3. **Phase 1 — Spec & e2e**: dispatch `code-forge:forge-planner`. The
   planner authors `.forge/spec.md` with all required blocks
   (see `templates/spec.md.template`), runs G2.a / G2.b Codex gates
   internally, runs the interactive Phase 1.5 Reviewer Config sub-step,
   emits `.forge/agent-config.md`, and mirrors each cycle's
   `goal_condition` into `state.json.cycles[<id>].goal_condition`.
4. **Cycle loop**: for each cycle in `spec.md ## Cycle Plan`, in order:
   - Skip if `cycles[<id>].status == "pass"`.
   - Update `state.json`: `current_cycle = <id>`,
     `cycles[<id>].status = "in_progress"`,
     `cycles[<id>].started_at = <now>`.
   - Read `cycles[<id>].goal_condition` from `state.json`.
   - Spawn the cycle child via Bash:
     ```bash
     claude -p "/goal ${CYCLE_GOAL}" \
       --add-dir .forge \
       --add-dir <files_affected paths>
     ```
   - Wait for the child to exit. Read `cycles/<id>/result.json`.
   - **Crash detection**: if the child's exit code is non-zero AND
     `result.json` doesn't exist, synthesize a fail result.json
     (status=`fail`, summary=`"child crashed (exit N) before writing
     result.json"`). Surface to user.
   - Narrate the status in transcript so the user can see it.
   - Update `state.json.cycles[<id>].status`.
   - If status is `fail`: halt the loop (the user can investigate and
     re-invoke `/forge --resume`).
5. **Done**: print a summary citing each cycle's `result.json.summary`
   and `review.md` path.

### What the skill does NOT do

- It does not set its own `/goal`. The skill is interactive — you can
  Ctrl+C, ask questions, or redirect mid-run.
- It does not loop indefinitely on a failed cycle. Halt + surface +
  let the user investigate.

## Per-cycle child session

### Entry

The skill spawns:

```bash
claude -p "/goal cycles/<id>/result.json exists with status: pass AND
        cycles/<id>/review.md has 0 critical clusters as surfaced in
        this transcript, or stop after K_child turns" \
  --add-dir .forge \
  --add-dir <files_affected paths>
```

`K_child` = 30 typical; raise to 50 for known-hard cycles.

### What the cycle child does

The cycle child reads its entry from `.forge/spec.md ## Cycle Plan`
(matched by `<id>`) and runs a linear sequence of dispatches + gates.
Each subagent's behavior is its own contract — see the per-agent `.md`
files. The cycle child only orchestrates:

1. Write `.forge/state.json` with `current_cycle: "<id>"` and
   `phase: "test-list"`. forge-guard's anti-weakening rule keys off
   `phase` later.
2. Dispatch **`forge-test-author`** — emits `tests.json` + the actual
   test files at the paths in `test_file`. See `agents/test-author.md`.
3. Run `bash scripts/cycle-tests-pass.sh red cycles/<id>/ -- <test-cmd>`.
   Exit 0 means tests failed correctly (red-phase passes); non-zero
   means tautological — re-dispatch test-author.
4. Update state to `phase: "green"`. forge-guard now blocks edits to
   `tests.json`, `state.json`, and any `test_file` path for the rest
   of the cycle.
5. Dispatch **6 `forge-implementer-worker`s** in a single assistant
   turn (parallel `Agent` calls). Each writes a candidate to
   `cycles/<id>/green/candidates/worker-K/files/`. See
   `agents/implementer-worker.md`.
6. Score candidates inline: stage each in a scratch worktree, run the
   test command, keep passers, pick the simplest (LOC → files →
   complexity proxy; ties to lowest worker number), apply via rsync.
   If no candidate passed, narrate the failure and let `/goal`
   re-prompt.
7. Dispatch **N `forge-reviewer`s** in a single assistant turn (count,
   model, and per-reviewer dimension from `spec.md ## Reviewer Config`).
   See `agents/reviewer.md` for the dimension-to-lens map.
8. Dispatch **`forge-consolidator`** — clusters reviewer findings
   inline, verifies critical/high against source, writes `review.md`
   with a machine-readable Cluster summary block. See
   `agents/consolidator.md`.
9. Parse `review.md`'s Cluster summary, surface the counts in
   transcript, then write `cycles/<id>/result.json` with
   `status: pass` if critical=0 else `fail`, plus `winner_worker`,
   `summary`, `review_clusters`. Update state to `phase: "done"`. Exit.

### What stops the cycle child

- Goal clears (status=pass + 0 critical in review).
- Turn cap (`or stop after K_child turns`) — child exits with whatever
  `result.json` it last wrote, even if `status: fail`. The skill
  surfaces the failure to the user.
- forge-guard rule 5 blocks a worker from editing a test file → the
  child notes the block, retries the worker with the same test list,
  doesn't weaken the test.

### Internal retry behavior (the `/goal` does this for free)

If the review has critical clusters — or no candidate passed the tests at
all — `result.json` gets `status: fail`. The evaluator sees `status: fail`
in transcript and verdicts "no", so Claude re-enters the cycle child's
procedure. The child can either:

- **Re-dispatch workers** for another best-of-N round (green retry), or
- **Re-dispatch a single repair worker** targeting just the critical
  files.

The cycle child's main session decides which path to take based on the
review's failure mode (e.g., universal failure → re-dispatch all
workers; single-file critical → repair worker).

#### Failed-Approaches Carry-Forward on retry (optional)

Before a green *retry* round, the cycle child distills the round that just
failed into `cycles/<id>/failures.md` (appending a `## Round N` section —
cumulative across the cycle). It does this **inline**: it already holds
the per-candidate test results, the `blocked:true` manifests, and
`review.md` in context, so no separate distiller agent is dispatched.

How many workers see that file is governed by the optional
`## Worker Config` block in `spec.md`:

- `hinted_workers: 0` (the default when the block is absent) -> every retry
  worker is **pristine**, exactly as before. The carry-forward is dormant.
- `hinted_workers: K` (1 <= K < count) -> the cycle child dispatches
  `count - K` pristine workers plus `K` **hinted** workers whose dispatch
  prompt names `failures.md` and instructs them to avoid the recorded
  dead-ends. Round 1 is always all-pristine (no failures exist yet).

Keeping the majority pristine is the whole point: if all retry workers saw
the failure history they would re-correlate and best-of-N would collapse
to best-of-1. The hinted minority is insurance against repeating a known
dead-end without sacrificing the pool's diversity. Full rationale +
artifact format: `failed-approaches-carryforward.md`.

The `/goal` re-prompt loop handles the "try again" mechanic. No retry
counter to maintain; the `or stop after K_child turns` clause is the
cap.

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
      "started_at": "2026-05-19T10:00:00Z",
      "goal_condition": "cycles/C1/result.json exists with status: pass AND cycles/C1/review.md has 0 critical clusters, or stop after 30 turns"
    },
    "C2": { "status": "pending", "goal_condition": "…" },
    "C3": { "status": "pending", "goal_condition": "…" }
  }
}
```

Writers:

- The `/forge` skill seeds the initial document and updates
  `current_cycle` + `cycles[<id>].status` between cycle spawns.
- The planner mirrors each cycle's `goal_condition` after Phase 1.
- The cycle child writes `phase` and reads `goal_condition`.

Consumers:

- **forge-guard** reads `current_cycle` + `phase` to enforce the
  anti-weakening rule during green.
- **The skill** reads `cycles[*].status` to pick the next pending cycle
  and `cycles[<id>].goal_condition` to construct each `claude -p`
  invocation.

Note: a single `phase` field is shared across the skill's outer flow
and the cycle child's inner flow. forge-guard only blocks on
`phase === "green"`, so other values are inert from the hook's POV. The
skill should reset `phase` to a non-green sentinel (e.g. `"done"`
after a cycle, `"plan"` between cycles) so a stale `"green"` doesn't
carry over into the next cycle's pre-test-list window.

## What `/goal` does NOT replace

The hooks layer (`forge-guard.mjs`) is **orthogonal** to `/goal` — the
`/goal` mechanism is itself a session-scoped Stop hook, and a Stop
hook can't enforce PreToolUse invariants. Test immutability has to
remain a PreToolUse hook; otherwise the cycle child's `/goal "tests
pass"` rewrites tests rather than the implementation, because the
evaluator only sees the transcript and cannot diff against a baseline.

`/goal` also does not handle cross-session state. The skill's
narration pattern (read `result.json` and surface its content in
transcript) exists specifically because each cycle child has its own
evaluator that can't read filesystem state directly.

## See also

- `templates/spec.md.template` — the spec.md skeleton with all the
  blocks the cycle children depend on.
- `skills/code-forge/SKILL.md` — the orchestrator the `/forge` command
  loads.
- `agents/planner.md` — Phase 1 spec-authoring procedure including the
  interactive Phase 1.5 Reviewer Config sub-step.
- `hooks/forge-guard.mjs` — the one surviving hook rule (test
  immutability).
