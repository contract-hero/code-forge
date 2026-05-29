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

Commentary on the example; would never appear in a real artifact.

- **Two `outcome` kinds shown.** Round 1 is `no-pass`; round 2 is
  `critical-review` (passed all tests, but `review.md` had a critical
  cluster). Both set `result.json status: fail` and trigger a `failures.md`
  append.

- **A passing round writes nothing.** Round 3 (Map-backed, 0 failed tests,
  0 critical clusters) clears the cycle's `/goal` — so no `## Round 3`
  section is appended. The last section of any `failures.md` is always the
  last *failed* round.

- **How the cycle child used this (round 2 dispatch).** With `## Worker
  Config` `count: 6, hinted_workers: 1`, round 2 dispatched workers 1-5
  pristine and worker 6 hinted. Worker 6 read Round 1, avoided D1, and went
  straight to a `Map`. One pristine worker (worker-2) still hit D2 — which
  is exactly why the pristine majority alone isn't enough and one hinted
  worker is cheap insurance.

- The example applies distillation policy rules 1 (approach-not-code),
  3 (dead-ends vs open questions), and 5 (cap). See the design doc for the
  rule definitions rather than re-reading them here.
