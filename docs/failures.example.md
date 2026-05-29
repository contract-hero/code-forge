# Failed approaches — cycle C2

> **Reference example** (not a live artifact). This is what the cycle child
> emits inline after each failed round of a hypothetical cycle C2 —
> "in-memory key-value index with O(1) lookup". It illustrates the
> `failures.md` contract from `failed-approaches-carryforward.md`:
> cumulative `## Round N` sections, both `outcome` kinds, the dead-end vs
> open-question distinction, and the distillation policy. Everything above
> the final `---` is faithful artifact content; the "Reference notes"
> section below the line is commentary and would NOT appear in a real file.

## Round 1
**Outcome:** no candidate passed (2 failed tests, 2 workers blocked).

### Dead-ends (do NOT repeat these)
- **D1** — Backed the index with a plain `Array` and linear-scanned on
  `get`. Lookup is O(n); `T-003 lookup-is-constant-time` times out at the
  10k-entry fixture. (workers 1, 3, 5 all converged here)

### Open questions (NOT dead-ends — surfaced for resolution)
- Duplicate-key semantics are unspecified: on `set(k, v)` for an existing
  `k`, should the index overwrite or reject? `T-006` asserts a behavior the
  cycle plan never pinned. Two workers (2, 6) emitted `blocked: true` with
  this exact reason rather than guess. **Action:** cycle child surfaces this
  to the user / planner; it is a spec gap, not an implementation failure.

### What's still open / promising
- worker-4 passed 7/9 tests with a `Map`-backed store, failing only `T-006`
  (the duplicate-key ambiguity above) and `T-008`. The `Map` direction is
  almost certainly correct once the duplicate-key rule is pinned.

```facf
round: 1
outcome: no-pass
failed_tests: [T-003, T-006]
blocked_reasons:
  - "duplicate-key semantics unspecified (set on existing key: overwrite vs reject?)"
dead_ends:
  - id: D1
    summary: "Array + linear scan -> O(n) get, times out T-003 at 10k entries"
open_questions:
  - "duplicate-key behavior on set() is unspecified; 2 workers blocked"
promising:
  - "Map-backed store (worker-4) passed 7/9; only the ambiguous cases open"
```

## Round 2
**Outcome:** a candidate passed every test, but review found a critical
cluster. (Duplicate-key rule was pinned to "last write wins" before this
round; the failing test count is therefore 0.)

### Dead-ends (do NOT repeat these)
- **D2** — Backed the index with a plain object literal (`const store = {}`)
  keyed by string. All 9 tests pass, but a key named `__proto__` (or
  `constructor`) mutates the prototype chain instead of storing an entry, so
  a later `get("__proto__")` returns the prototype and `has()` reports
  phantom keys. Reviewer flagged this **critical (security/correctness)**;
  no test covers adversarial key names. (winner of round 2: worker-2)

### What's still open / promising
- The `Map`-backed approach first seen in round 1 (worker-4) has none of
  this — `Map` keys are not coerced onto a prototype. A `Map` store passes
  the same 9 tests *and* sidesteps D2. Round 3 should use `Map` (or a
  null-prototype object) and is expected to clear review.

```facf
round: 2
outcome: critical-review
failed_tests: []
blocked_reasons: []
dead_ends:
  - id: D2
    summary: "Plain-object {} backing store -> __proto__/constructor keys corrupt lookups; critical, untested"
open_questions: []
promising:
  - "Map-backed store passes all 9 tests and avoids D1 and D2; use it in round 3"
```

---

## Reference notes (NOT part of a real failures.md)

These notes explain *why* the example looks the way it does — they would
never appear in an artifact the cycle child writes.

- **Two `outcome` kinds shown.** Round 1 is `no-pass` (no candidate even
  passed the tests). Round 2 is `critical-review` (a candidate passed all
  tests but the consolidator's `review.md` had a critical cluster). Both
  set `result.json status: fail` and both trigger a `failures.md` append.

- **Dead-end vs open question.** D1 and D2 are genuine *wrong directions* —
  record them so a hinted worker avoids them. The duplicate-key ambiguity
  in round 1 is **not** a dead-end: the approach was never wrong, the spec
  was underspecified. Per distillation policy rule 3, that goes under
  *open questions* and the cycle child escalates it rather than retrying
  blindly; a recurring open question is a signal to stop and ask the user.

- **Approach, not code (policy rule 1).** Every dead-end names the
  *direction* ("Array + linear scan", "plain-object backing store"), never
  the failed diff. A hinted worker that received the diff would be tempted
  to patch it and re-anchor on the loser; a direction lets it route around.

- **Cumulative, append-only.** Round 2's section sits below Round 1's; a
  worker hinted on round 2 sees both D1 and D2. The `facf` machine blocks
  are per-round so the cycle child can `grep`/parse the latest without
  re-reading prose.

- **A passing round writes nothing.** Round 3 (Map-backed, 0 failed tests,
  0 critical clusters) clears the cycle's `/goal` — so no `## Round 3`
  section is ever appended. The last section of any `failures.md` is always
  the last *failed* round. If you see a `failures.md` whose final round
  passed, something wrote it incorrectly.

- **Cap respected (policy rule 5).** Each round lists a single dead-end
  here; real rounds may list a few, but > 5 distinct failure modes in one
  round means the spec/tests are the problem, not the implementations.

- **How the cycle child used this (round 2 dispatch).** With a spec setting
  `## Worker Config` `count: 6, hinted_workers: 1`, round 2 dispatched
  workers 1-5 pristine and worker 6 hinted. Worker 6 read this file's
  Round 1 section, avoided D1 (no array), and went straight to a `Map`.
  Workers 1-5 explored freely; one of them (worker-2) still hit D2 with a
  plain object — which is exactly why the pristine majority is not enough on
  its own, and exactly why a single hinted worker is cheap insurance.
