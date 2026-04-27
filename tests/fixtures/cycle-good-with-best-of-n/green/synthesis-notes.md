# Green-phase synthesis — cycle 1

## Pick
worker-4 — score=4 (LOC=3, files=1, complexity-proxy=1)

## Candidate scores

| Worker | Pass | LOC | Files | Complexity | Notes |
|---|---|---|---|---|---|
| 1 | yes | 4 | 1 | 2 | small guard for empty string adds 1 LOC vs worker-4 |
| 2 | blocked | - | - | - | "contract ambiguous on cursor sequences" |
| 3 | yes | 19 | 1 | 6 | extra utility helper not under test; over-engineered |
| 4 | yes | 3 | 1 | 1 | **chosen** — minimum code that passes |
| 5 | yes | 4 | 2 | 1 | same as 4 plus index.ts re-export — extra file not in scope |
| 6 | no | - | - | - | T-002 failed: regex replaces only the leading escape, not the closing sequence |

## Diversity signal
Workers 1, 4, 5 converged on the same regex approach (variance in micro-details
only); worker-3 took a heavier path; worker-2 blocked on contract ambiguity;
worker-6 attempted a non-regex path and failed. Diversity = medium. No "all
converged on the same wrong answer" red flag.
