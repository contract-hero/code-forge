# `/goal` integration — Option D architecture

Code Forge v0.2.0 (Option D) replaces the hand-rolled cycle state machine
with two nested `/goal` sessions. This document is the procedure manual the
human and the outer Claude session read when driving the protocol; it
replaces the previous `forge-orchestrator.md` and `implementer.md` files.

The protocol is straightforward:

```
top:   claude -p "/goal <outer condition>"    ← runs in your shell
         │
         ▼ (outer Claude reads spec, picks next cycle, spawns child)
cycle: claude -p "/goal <per-cycle condition>"  ← spawned via Bash
         │
         ▼ (cycle child writes tests, runs best-of-N, fan-out review)
       result.json   ← outer reads, narrates "cycle X status:pass"
```

`/goal` is one-goal-per-session. We sidestep the nested-goal limit by using
session boundaries: each `claude -p` is a fresh session with its own goal.
Each session also has its own evaluator (a small fast model — Haiku by
default — that judges the goal condition against the transcript after every
Claude turn).

## Outer goal session

### Entry

The user runs `bash scripts/forge.sh <task description>` (or invokes the
`/forge` command, which wraps it). `forge.sh` spawns:

```bash
claude -p "/goal every cycle id in .forge/spec.md ## Cycle Plan
       has a corresponding cycles/<id>/result.json file containing
       status: pass — as surfaced in this session's transcript via
       narration of each child session's exit — or stop after K outer turns"
```

`K` = `len(cycles) + 5`. Reasoning: most outer turns are "spawn child, read
result.json, narrate." Five extra turns cover Phase 0/1/2 spec authoring,
unexpected re-prompts, and final summary.

### What the outer Claude does each turn

1. **Phase 0 — Plan** (skip if `--quick`): wrap `codex-bridge:claudex` on
   the lazy prompt. Land `.forge/plan.md`.
2. **Phase 1 — Spec & e2e**: dispatch `forge-planner`. The planner authors
   `.forge/spec.md` with all required blocks (see `templates/spec.md.template`),
   runs the two Codex gates (G2.a, G2.b) internally, runs the interactive
   Phase 1.5 Reviewer Config sub-step (model + dimensions), and emits
   `.forge/agent-config.md` for routing hints.
3. **Cycle loop**: read `.forge/spec.md ## Cycle Plan` and `.forge/state.json`.
   For each cycle entry whose status is not `pass`:
   - **Spawn the child session** via Bash. The planner mirrors each
     cycle's `goal_condition` into `state.json.cycles[<id>].goal_condition`
     at Phase 1f so `jq` reads what the outer session actually invokes:
     ```bash
     CYCLE_GOAL=$(jq -r ".cycles[\"<id>\"].goal_condition // empty" .forge/state.json)
     [ -z "$CYCLE_GOAL" ] && { echo "spec missing goal_condition for <id>"; exit 1; }
     claude -p "/goal ${CYCLE_GOAL}" \
       --add-dir .forge \
       --add-dir <cycle's files_affected paths>
     ```
   - **Wait for child exit**. The child writes `cycles/<id>/result.json`
     with `status: pass` or `status: fail` before exiting.
   - **Detect a child crash**: if the child's exit code is non-zero AND
     `result.json` does not exist, treat that as `status: fail` and write
     a synthetic `result.json` (status=`fail`, summary=`"child crashed
     before writing result.json (exit N)"`) plus a one-line note in
     transcript so the evaluator sees the failure. Then move on — do NOT
     loop respawning a crashing child against the K_OUTER budget. The
     user can re-run with `--resume` after investigating.
   - **Read `result.json`**. Surface it explicitly in the transcript:
     ```
     Cycle C1 child exited. Reading .forge/cycles/C1/result.json:
       { "status": "pass", "summary": "all tests pass; 0 critical findings",
         "winner_worker": "W3", "review_clusters": { "critical": 0, "high": 2 } }
     Cycle C1 complete with status=pass. Moving to cycle C2.
     ```
     The evaluator can only judge what's in the transcript. Narrate
     explicitly — don't rely on the evaluator inferring state from
     filesystem reads it can't see.
4. **Done**: once every cycle has `status: pass`, the outer goal clears.
   The outer Claude prints a final summary and exits.

### What stops the outer loop

- Evaluator says "yes" (every cycle has pass) → goal clears, session ends.
- The "or stop after K outer turns" clause caps the loop at K turns.
- User interrupts with Ctrl+C.
- A cycle child writes `status: fail` and the outer Claude exits after
  surfacing the failing cycle's `result.json.summary` to the user. The
  outer narrates "cycle X failed — see cycles/X/review.md for details" and
  lets the evaluator's verdict end the run.

## Per-cycle child session

### Entry

The outer Claude spawns:

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
Each subagent's behavior is its own contract — see the per-agent .md
files for the procedure. The cycle child only orchestrates:

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
8. Dispatch **`forge-consolidator`** — clusters reviewer findings inline,
   verifies critical/high against source, writes `review.md` with a
   machine-readable Cluster summary block. See `agents/consolidator.md`.
9. Parse `review.md`'s Cluster summary, surface the counts in
   transcript, then write `cycles/<id>/result.json` with `status: pass`
   if critical=0 else `fail`, plus `winner_worker`, `summary`,
   `review_clusters`. Update state to `phase: "done"`. Exit.

### What stops the cycle child

- Goal clears (status=pass + 0 critical in review).
- Turn cap (`or stop after K_child turns`) — child exits with whatever
  `result.json` it last wrote, even if `status: fail`. The outer surfaces
  the failure to the user.
- forge-guard rule 5 blocks a worker from editing a test file → the child
  notes the block, retries the worker with the same test list, doesn't
  weaken the test.

### Internal retry behavior (the `/goal` does this for free)

If the review has critical clusters, `result.json` gets `status: fail`. The
evaluator sees `status: fail` in transcript and verdicts "no" — Claude
re-enters the cycle child's procedure. The child can either:
- **Re-dispatch workers** with the reviewer feedback as additional context
  (green retry), or
- **Re-dispatch a single repair worker** targeting just the critical files.

The cycle child's main session decides which path to take based on the
review's failure mode (e.g., universal failure → re-dispatch all workers;
single-file critical → repair worker).

The `/goal` re-prompt loop handles the "try again" mechanic. No retry
counter to maintain; the `or stop after K_child turns` clause is the cap.

## State schema (Option D)

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

Consumers:
- **forge-guard** reads `current_cycle` + `phase` to enforce the
  anti-weakening rule during green.
- **Outer Claude** reads `cycles[*].status` to pick the next pending
  cycle and `cycles[<id>].goal_condition` to know what `/goal` to set
  on the spawned child.

Writers:
- `scripts/forge.sh` seeds the initial document (no `phase`, no
  `goal_condition` — those come later).
- `forge-planner` mirrors each cycle's `goal_condition` from
  `spec.md ## Cycle Plan` into `cycles[<id>]` at the end of Phase 1.
- The cycle child writes `current_cycle` + `phase` during its run.
- The outer writes `cycles[<id>].status` after each child exits.

Note: a single `phase` field is shared across pre-cycle and per-cycle
work. forge-guard only blocks on `phase === "green"`, so other values
are inert from the hook's POV — but the outer Claude should reset
`phase` to a non-green sentinel (e.g. `"done"` after a cycle, `"plan"`
between cycles) so a stale `"green"` doesn't carry over into the next
cycle's pre-test-list window. See R2-002 in the initial review for the
known tradeoff vs. fully splitting outer/inner state into two files.

## What `/goal` does NOT replace

The hooks layer (forge-guard rule 5) is **orthogonal** to `/goal` — `/goal`
itself IS a session-scoped Stop hook, and the Stop hook can't enforce
PreToolUse invariants. Test immutability has to remain a PreToolUse hook;
otherwise `/goal "tests pass"` will rewrite tests rather than the
implementation, because the evaluator only sees the transcript and cannot
diff against a baseline.

`/goal` also does not handle cross-session state. The outer-state
narration pattern (the outer Claude reads `result.json` and re-emits its
content to the transcript) exists specifically because the outer
evaluator can't read filesystem state directly.

## See also

- `templates/spec.md.template` — the spec.md skeleton with all 10 blocks
  the cycle children depend on.
- `agents/planner.md` — Phase 1 spec-authoring procedure including the
  interactive Phase 1.5 Reviewer Config sub-step.
- `hooks/forge-guard.mjs` — the one surviving hook rule (test immutability).
- `scripts/forge.sh` — the top-level launcher that invokes the outer goal.
