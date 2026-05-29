# Design: Review-stage Workflow (Workflows-native code-forge, PR #1)

> Status: design / awaiting review · Date: 2026-05-29 · Author: alilloig
> Scope of this spec: **PR #1** — port the read-only reviewer + consolidator
> stage to a Claude Code **Workflow**, invoked from the interactive `/forge`
> skill. The broader migration (retire `claude -p`) is recorded in §Roadmap
> as context; it is NOT implemented here.

## Goal

Make code-forge genuinely use the Claude Code **Workflow** tool, starting
with its lowest-risk stage. The strategic goal is a **Workflows-native
code-forge**: the interactive `/forge` skill orchestrates each cycle by
invoking Workflows, and the per-cycle `claude -p "/goal …"` children are
retired. PR #1 lands the first, read-only piece and proves the pattern.

## The hard constraint that drives the whole design

A `claude -p` (headless / print-mode) process **cannot use the Workflow
tool**. Three independent confirmations:

1. The Workflow/Task tools are **not exposed in headless `claude -p`**
   (anthropics/claude-code#20463).
2. A `-p` run **exits when its turn ends**, before any background workflow
   completes — orphaning it (anthropics/claude-code#29193). The caller
   cannot consume the workflow's return value.
3. There is **no synchronous/blocking await** for a workflow in headless.

Therefore Workflows can only run in an **interactive** session. Code-forge's
current `claude -p "/goal …"` per-cycle child **cannot invoke a Workflow**.
Any use of Workflows must be driven by the interactive `/forge` skill. This
is structural, not a permissions tweak.

**Consequence:** "code-forge uses Workflows" ⟹ orchestration moves out of
`claude -p` children and into the `/forge` skill, and the children are
progressively retired. See §Roadmap.

## North-star architecture (context for PR #1)

```
Today:                          North star:
  /forge skill (interactive)      /forge skill (interactive)
    └─ spawn claude -p /goal        └─ runs each cycle as a WORKFLOW
         (per cycle)                     - red (test-author agent)
         red→green→review→result         - green best-of-N (parallel workers)
                                          - review (parallel reviewers→consolidator)
                                          - retry = JS while-loop (was /goal recursion)
  forge-guard PreToolUse hook       structural test-immutability
    enforces test immutability        (canonical-test scoring + checksum gate)
                                      (hooks do NOT reach Workflow agents)
```

Fresh-context worker isolation is preserved — Workflow agents get isolated
context windows, so best-of-N decorrelation survives. What is replaced is
the per-cycle OS process + `/goal` Haiku evaluator, which become explicit,
deterministic JS control flow inside the cycle Workflow.

## PR #1 scope — the review-stage Workflow

### Why this stage first

The reviewer→consolidator stage is **read-only**: reviewers analyze source
and emit findings; the consolidator only writes `review.md`. Nothing touches
source or test files, so the test-immutability problem (which blocks the
green stage — hooks don't govern Workflow agents) is **irrelevant here**. It
is the safest place to introduce Workflows and prove `parallel()` + schema +
the dedup barrier.

### Boundary

The **`/forge` skill** (interactive) invokes the review Workflow once per
cycle, after the cycle's green child has exited.

- **Invoker:** the `/forge` skill (NOT the `claude -p` child — see constraint).
- **In (args):** `{ cycleDir, specPath, dimensions: [...], model, sourceFiles: [...] }`,
  read from the cycle's `## Reviewer Config` and `files_affected`.
- **Out (return value):** `{ critical, high, medium, low, info, reviewMdPath }`.

### Cycle-ownership change (transitional)

- The `claude -p "/goal …"` cycle child's goal **narrows to "green passes"**
  (red → green → pick-best → write a green-only `result.json`, then exit).
  It drops the "0 critical clusters" clause.
- After the child exits, the `/forge` skill runs the review Workflow and
  **merges the returned cluster summary into `result.json`** (adding
  `review_clusters` and flipping `status` to `fail` if `critical > 0`).
- **Retry-on-critical is deferred (transitional).** Today the child's
  `/goal` loop re-dispatched workers when review found criticals. With review
  moved to the skill and the child already exited, PR #1 does **not**
  auto-retry: a `critical > 0` review sets `result.json status: fail` and the
  skill halts + surfaces to the user — matching the skill's existing on-fail
  behavior. The worker-retry-on-critical loop (with FACF hinting) returns
  natively in PR #2, when green + review live in one Workflow and retry is a
  JS loop. This is a temporary, accepted behavior regression.
- This split is transitional scaffolding. PR #2/#3 fold green into the
  skill-run Workflow too, at which point there is no child to coordinate
  with and `result.json` is written in one place.

### The Workflow script — `workflows/review-stage.mjs`

Ships in the plugin; invoked with `scriptPath:
${CLAUDE_PLUGIN_ROOT}/workflows/review-stage.mjs`.

```js
export const meta = {
  name: 'forge-review-stage',
  description: 'Dimensional reviewers + consolidation for one cycle',
  phases: [{ title: 'Review' }, { title: 'Consolidate' }],
}
// args: { cycleDir, specPath, dimensions, model, sourceFiles }
const { cycleDir, specPath, dimensions, model } = args

phase('Review')
const results = await parallel(dimensions.map((dim, i) => () =>
  agent(reviewerPrompt({ cycleDir, specPath, dimension: dim, reviewerIndex: i + 1 }),
    { label: `review:${dim}#${i + 1}`, model,
      agentType: 'code-forge:forge-reviewer', schema: FINDINGS_SCHEMA })))

// deterministic dropout detection: a failed reviewer -> null
const realized = results.filter(Boolean)
const dropped  = dimensions.filter((_, i) => !results[i])
// persist each reviewer's findings to cycles/<id>/reviewers/subagent-K.json (forensics)

phase('Consolidate')   // barrier: consolidation needs ALL findings to cluster/dedup
const summary = await agent(
  consolidatorPrompt({ cycleDir, specPath, realizedCount: realized.length, dropped }),
  { agentType: 'code-forge:forge-consolidator', schema: CLUSTER_SUMMARY_SCHEMA })

return summary   // { critical, high, medium, low, info, reviewMdPath }
```

Load-bearing decisions:

1. **`parallel()` barrier, not `pipeline()`.** Consolidation legitimately
   needs every reviewer's findings at once (cross-item clustering/dedup) —
   the textbook case where a barrier is correct.
2. **Reuse existing agent contracts as `agentType`.** `forge-reviewer` and
   `forge-consolidator` carry over in role unchanged; the Workflow only
   orchestrates them. Their read-only tool allowlists already fit. (Custom
   `agentType` + custom prompt + read-only tools are all supported.)
3. **Dropout detection in the script.** `parallel()` yields `null` for a
   failed reviewer, so realized-vs-configured count is deterministic JS,
   replacing the consolidator's file-counting Step 0. The consolidator is
   *told* the dropouts and still emits the synthetic-coverage cluster.

### Schemas (the capability win)

- **`FINDINGS_SCHEMA`** — JSON Schema mirroring today's `subagent-N.json`
  schema: array of objects with `id` (pattern `^R<k>-\d{3}$`), `title`,
  `severity` (enum), `category` (enum), `file`, `line_range`, `description`,
  `impact`, `recommendation`, `evidence`, `confidence` (enum). The Workflow
  `schema` option forces conforming output with retry-on-mismatch — moving
  validation **upstream to dispatch time**. The reviewer **returns** the
  array; the script persists it to `subagent-K.json` for forensics.
- **`CLUSTER_SUMMARY_SCHEMA`** — `{ critical, high, medium, low, info: int,
  reviewMdPath: string }`. The consolidator **returns** this AND still writes
  `review.md` for humans. The skill consumes the object directly into
  `result.json.review_clusters` — eliminating the brittle "parse the
  byte-stable markdown Cluster summary block" contract.

### Validation: single source of truth (decision)

`FINDINGS_SCHEMA` is the **one** authoritative findings schema, enforced at
dispatch. `subagent-K.json` files are still persisted for forensics but are
**no longer a gate**. `cycle-validate.sh`'s `validate_reviewer` function is
retained only where `forge-smoke` fixtures exercise it; it is not the live
gate. This avoids the two-schema drift (JSON Schema + hand-coded jq) that a
belt-and-suspenders approach would create.

### Files PR #1 touches

| File | Change |
|---|---|
| `workflows/review-stage.mjs` | **new** — the review Workflow script + the two schemas |
| `skills/code-forge/SKILL.md` | cycle loop: after the green child exits, invoke the review Workflow and merge its summary into `result.json`; note allowed-tools |
| `docs/goal-integration.md` | cycle-child steps 7-8 removed (review leaves the child); child `/goal` narrows to "green passes"; skill owns review→result |
| `agents/reviewer.md` | reviewer **returns** schema-validated findings (workflow persists `subagent-K.json`); dispatched by the workflow |
| `agents/consolidator.md` | consolidator **returns** `CLUSTER_SUMMARY` + still writes `review.md`; dropout count comes from the script |
| `templates/spec.md.template` | (no schema change) note that Reviewer Config now feeds the review Workflow args |
| `tests/` (forge-smoke) | a fixture cycle dir + a dry-run that asserts the workflow returns a well-formed summary and writes `review.md` |
| `cycle-validate.sh` | demote `validate_reviewer` from live gate to fixture-only (documented) |

### Testing / verification

- **forge-smoke fixture:** a canned `cycles/CX/` with pre-written
  `subagent-*.json`-equivalent inputs and source files; run `review-stage.mjs`
  and assert (a) it returns a `CLUSTER_SUMMARY_SCHEMA`-valid object, (b) it
  writes a `review.md` with a Cluster summary block whose counts match the
  returned object, (c) a deliberately-malformed reviewer return triggers the
  schema retry path rather than a silent bad write.
- **Manual end-to-end:** run `/forge` on a tiny PoC; confirm the skill invokes
  the review Workflow after green and `result.json.review_clusters` matches
  `review.md`.

## Roadmap (north star; not in PR #1)

- **PR #2 — green best-of-N as a Workflow.** Move the green phase into a
  skill-run Workflow: `parallel()` N implementer workers (some **hinted** on
  retry = FACF, native here), candidate scoring against **canonical** test
  files, and **structural test-immutability** (checksum gate ± a `Stop` hook)
  replacing the `forge-guard` PreToolUse hook (which does not govern Workflow
  agents). FACF design assets from the parked PR #10 land here, live.
- **PR #3 — retire `claude -p`.** The cycle becomes one Workflow (or a short
  sequence) the `/forge` skill runs per cycle; the `/goal` retry recursion
  becomes a JS `while`/loop-until-pass; `result.json` written in one place.
  No `claude -p` children remain.

## Risks / open items

- **forge-guard becomes inert for Workflow-run stages.** Acceptable in PR #1
  (review is read-only). PR #2 must land structural test-immutability before
  any code-writing stage runs as a Workflow.
- **Skill ↔ child coordination is transitional.** The narrowed-`/goal` +
  skill-merges-result split exists only until PR #2 absorbs green. Keep it
  thin; don't over-invest in the child↔skill handshake.
- **Workflow invocation from the skill must be reliable in the user's
  session.** The skill is the sanctioned opt-in path (a skill instructing
  Workflow). Confirm the cycle loop awaits the workflow's completion
  notification before merging results.
- **`agentType` resolution for plugin agents inside a Workflow** (the
  `code-forge:forge-reviewer` form) must resolve from the same registry as
  the Agent tool — validate early in implementation.
- **Temporary loss of in-cycle critical-retry.** PR #1 trades the child's
  `/goal` worker-retry-on-critical for halt-and-surface. If this regression
  is unacceptable to ship between PR #1 and PR #2, the skill can re-spawn the
  green child + re-run review on `critical > 0` up to a cap — but that adds
  child↔skill retry coordination we would throw away in PR #2. Default:
  accept the regression; revisit only if PR #2 slips.

## Non-goals (PR #1)

- No change to red phase, green best-of-N, candidate scoring, or FACF.
- No structural test-immutability work (that is PR #2's gate).
- No removal of `claude -p` (that is PR #3).
- No change to the `FINDINGS` field set or the `## Reviewer Config` schema.
