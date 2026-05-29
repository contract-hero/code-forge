# Failed-Approaches Carry-Forward (FACF)

> Status: design proposal · v1 scope: **intra-cycle retry rounds only**
> (inter-cycle aggregation is a documented extension, not built).
> Author: alilloig · companion to `goal-integration.md`.

## The problem this solves

Code Forge's green phase is **best-of-N**: the cycle child dispatches N
(default 6) `forge-implementer-worker`s in a single turn, each in its own
fresh context, blind to the others. That blindness is *load-bearing* —
it's what decorrelates the candidates so the pool explores genuinely
different minimal solutions. Best-of-N only pays off when the N samples
are independent; sharing context collapses them toward one solution and
one set of blind spots (see `workflows-vs-code-forge.html` for the longer
argument).

But independence has one cost: **dead-end amnesia**. When a round fails
(no candidate passes, or the review surfaces a critical cluster) and
`/goal` re-enters the cycle child for a retry, the next round of workers
starts pristine again — and may cheerfully rediscover the *same* dead-end
N more times. Today the retry path (`goal-integration.md` §"Internal
retry behavior") says the child "can re-dispatch workers with the reviewer
feedback as additional context", but that context is **ad-hoc and
unstructured**: whatever the cycle child happens to paste. There is no
durable, distilled artifact, and no rule about *which* workers see it.

FACF formalizes exactly that retry context — and, critically, scopes it
so it does **not** re-correlate the whole pool.

## The core idea: a hybrid pool, not shared context

The naive fix ("show all retry workers the previous failures") throws away
the decorrelation we paid for — every worker now anchors on the same
narrative and the pool re-collapses. FACF instead keeps **most workers
pristine** and gives the distilled failure note to **only a small subset**:

```
Round 1 (no failures exist yet):
  W1 W2 W3 W4 W5 W6   <- all pristine. Full diversity.

Round 2+ (a dead-end is now KNOWN):
  W1 W2 W3 W4 W5      <- still pristine. Still exploring freely.
              W6      <- hinted: reads failures.md, told to AVOID the dead-ends.
```

You get both properties at once:

- **Anti-anchoring diversity** from the pristine majority — they might
  independently find a path the failure note would have biased them away
  from.
- **Dead-end avoidance** from the hinted minority — at least one worker is
  guaranteed not to repeat the known-bad approach.

Because the selector downstream (tests, then reviewers) only keeps the
*best* candidate, adding a hinted worker is pure upside: if the hint helps
it wins, if not it loses selection. In best-of-N only the ceiling matters,
never the floor.

## The artifact: `failures.md`

Written by the **cycle child, inline** (it already holds the candidate
scores, blocked manifests, and `review.md` in context — no separate
distiller agent), after **any failed round**, at:

```
.forge/cycles/<id>/failures.md
```

It is **cumulative within the cycle**: each retry round appends a new
`## Round N` section rather than overwriting, so a worker hinted on round 4
sees every dead-end from rounds 1-3.

`failures.md` is **never scaffolded empty** by `cycle-init.sh`. Its mere
existence is the signal "at least one round has failed in this cycle".
A worker checks for it; absence means round 1 (pristine for everyone).

### Format — human-readable prose + a machine block

Mirrors `review.md`'s convention (readable narrative + a fenced
machine-parseable summary the next step can `jq`/grep):

````markdown
# Failed approaches — cycle C2

## Round 1
**Outcome:** no candidate passed (2 failed tests, 2 blocked).

### Dead-ends (do NOT repeat these)
- **D1** — Stored the index as a plain `Array` and linear-scanned on
  lookup. Caused `T-003 lookup-is-O(1)` to time out. (workers 1,3,5)

### Open questions (NOT dead-ends — a spec gap to surface)
- Duplicate-key semantics unspecified: 2 workers blocked rather than
  guess. Escalate; don't keep retrying on an ambiguity.

### What's still open / promising
- worker-4 passed 7/9 tests with a Map-backed store; failed only on the
  duplicate-key case. A Map approach is likely correct once the rule is pinned.

```facf
round: 1
outcome: no-pass            # no-pass | critical-review
failed_tests: [T-003, T-007]
blocked_reasons:            # raw: what workers reported when blocked:true
  - "duplicate-key semantics unspecified"
dead_ends:                  # wrong directions to avoid next round
  - id: D1
    summary: "Array + linear scan -> O(n) lookup, times out T-003"
open_questions:             # distilled spec-gaps (NOT dead-ends); escalate
  - "duplicate-key behavior on set() unspecified"
promising:
  - "Map-backed store passed 7/9; only duplicate-key case open"
```
````

> A complete two-round worked example lives in `failures.example.md`.

### Distillation policy (what to put in — and what to leave out)

The whole value of FACF lives in this policy. Too much detail and the
hinted worker just re-implements the previous loser verbatim (re-anchoring
of the worst kind); too little and the note is useless. Rules:

1. **Record the approach, not the code.** "Array + linear scan timed out"
   — never the failed diff. A dead-end is a *direction*, not a patch.
2. **Always include the failing test ids and blocked reasons** — those are
   facts, not interpretation, and they're what the worker must satisfy.
3. **Distinguish dead-ends from open questions.** A blocked-on-ambiguity
   reason is not a dead-end (the approach was never wrong) — it's a spec
   gap to surface, and if it recurs the cycle child should escalate to the
   user rather than keep retrying.
4. **Keep `promising` honest and short.** One line on the closest near-miss
   gives the hinted worker a foothold without dictating the solution.
5. **Cap it.** Distill to <= 5 dead-ends per round. If a round produces
   more distinct failure modes than that, the spec/tests are likely the
   problem, not the implementations.

## Configuration: the optional `## Worker Config` block

New, **optional** block in `spec.md` (validator change: none — required
sections are presence-checked and extra blocks are allowed):

```yaml
count: 6            # best-of-N pool size (previously the implicit "default 6")
hinted_workers: 1   # how many of `count` receive failures.md on a RETRY round
```

- **Absent block => `count: 6, hinted_workers: 0`** — behaviorally
  identical to pre-FACF Code Forge. The feature ships *dark*: it only
  activates when a spec author deliberately sets `hinted_workers >= 1`.
- `hinted_workers` only takes effect on **round >= 2** (round 1 has no
  failures, so everyone is pristine regardless).
- Constraint: `hinted_workers < count` (you must always keep at least one
  pristine worker, or the pool re-correlates and FACF defeats itself).
  Recommended ceiling: `hinted_workers <= count / 3`.

## Lifecycle

```
round R of cycle <id>:
  cycle child dispatches `count` workers in one turn:
    if R == 1 OR hinted_workers == 0:
        every worker pristine (no failures.md in dispatch prompt)
    else:
        workers 1..(count - hinted_workers)       -> pristine
        workers (count - hinted_workers + 1)..count -> hinted
            (dispatch prompt names failures.md as an input + the
             "avoid these dead-ends" directive)
  score candidates -> pick best (unchanged)
  if round failed (no-pass OR critical cluster):
      cycle child distills this round into failures.md (append ## Round R)
      /goal re-prompts -> round R+1
```

## Why inline distillation (not a dedicated agent)

The cycle child finishes a round already holding everything FACF needs:
the per-candidate test results, the `blocked:true` manifests with reasons,
and the consolidator's `review.md` cluster summary. A separate
`forge-failure-distiller` agent would re-read all of that into fresh
context for marginal decorrelation benefit — distillation is summarization,
not generation, so it doesn't need an independent perspective the way a
worker or reviewer does. Inline keeps Code Forge's agent count minimal
(a stated design value) at the cost of one extra responsibility on the
cycle child, paid only on rounds that actually fail.

## Out of scope for v1 (documented extensions)

- **Inter-cycle carry-forward.** A cumulative `.forge/lessons.md`
  aggregating cross-cycle dead-ends (e.g. "every cycle that touched the
  auth module tripped on token refresh"). Higher risk of stale/irrelevant
  hints bleeding across cycle boundaries; defer until intra-cycle FACF is
  validated on real runs.
- **Making `hinted_workers` default to >= 1.** Ship dark first; flip the
  default only after A/B evidence that hinted retries raise pass rate.
- **Feeding `promising` near-misses as a seed candidate** (warm-start one
  worker from the closest passer's approach). Tempting, but a warm start
  is much closer to shared context than a one-line hint — evaluate
  separately.

## Files this proposal touches

| File | Change |
|---|---|
| `docs/failed-approaches-carryforward.md` | this doc (new) |
| `docs/failures.example.md` | worked reference example (new) |
| `templates/spec.md.template` | add optional `## Worker Config` block |
| `agents/implementer-worker.md` | add optional `failures.md` input + pristine/hinted rule |
| `docs/goal-integration.md` | rewrite §"Internal retry behavior" around `failures.md` |
| `scripts/cycle-init.sh` | comment: `failures.md` is round-driven, not scaffolded |

The runtime that *writes* `failures.md` and *chooses* hinted workers is the
cycle child's orchestration prose (in `goal-integration.md`), consistent
with how the rest of Code Forge's "logic" lives in agent/doc contracts
rather than code.
