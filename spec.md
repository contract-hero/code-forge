# Code-Forge v2 — Specification

Living document. Drafted 2026-04-25. Amended 2026-04-25 with five v0.2.0 design changes (see §0).

- **v0.1.0** is the first shipped version (commit `b518897`, smoke 19/19 green).
- **v0.2.0** is a design-only amendment in this document, not yet implemented in the plugin tree. Implementation deferred to a separate session.

This is the buildable spec. Phase 1 of the implementation plan starts from here, not from `~/.claude/plans/i-want-to-take-declarative-crayon.md` — the plan file is internal scratch; this file is what another agent (or future-you) needs to execute.

---

## 0. v0.2.0 design amendments (summary)

Five changes proposed during a design review of v0.1.0. They interlock more than they look at first glance.

| # | Change | Affects |
|---|---|---|
| **A** | **Codex-mediated Phase 0** with plan-mode + AskUserQuestion (wraps `codex-bridge:claudex` skill). Replaces the old intent + prompt-refinement + parts of spec-critique. | §4.1, §4.9 (new), pre-cycle structure |
| **B** | **E2E tests as cross-cycle invariant.** Spec gains a `## E2E Tests` section. New post-cycles **Phase F (e2e-review)** runs them; reuses `reviewer` ×N over scenarios. Chrome MCP for frontend products. | §4.10 (new), §5, §6, §7, §9 |
| **C** | **Best-of-N implementer.** Green phase becomes 1 Opus coordinator + N Sonnet workers (default `IMPLEMENTERS=6`, tunable). Synthesis is **pick-best** (not merge): coordinator runs each candidate against tests, picks the simplest that passes. | §4.6 (new), §5, §6, §7 |
| **D** | **Specialist routing + recommended-agents roster + project-domain compound routing.** Phase 1 emits `agent-config.md` with THREE blocks: `project_domains` (top-level tags like `sui-dapp` — when present, force sui-pilot subagent for ALL Task dispatches regardless of file), `required_subagents` (hard glob-based routing for projects without a domain tag), `recommended_agents` (soft roster, curated from user's enabled-plugins set, favoring sui-pilot / impeccable / superpowers/\*). Role behavior is delivered via prompt-injection when project_domain forces a specific subagent. Forge-guard rule 6 hard-blocks subagent_type mismatches. | §4.7, §4.7.2, §7.5, §8 |
| **E** | **Pre-cycle compressed 7 → 3.** Phase 0 (Plan), Phase 1 (Spec & e2e), Phase 2 (Cycle plan). Old `intent`, `prompt-refinement`, `agent-detection`, `specification`, `spec-critique` all fold in. | §4.9, §4.10 (new), pre-cycle structure |

Why they interlock: A+E give the orchestrator a single "plan-then-spec-then-cycle" entrypoint with Codex G1+G2 cross-checks built in. B promotes e2e to *the* TDD-as-glue mechanism between cycles, which the v0.1.0 design lacked. C makes individual cycles' green-phase code higher quality through diversity-and-selection. D makes A/B/C all work correctly when the domain demands a specialist (Sui, frontend, etc.) — a pre-condition, not an afterthought.

Decisions taken during the review:

- **C: N=IMPLEMENTERS env var, default 6, pick-best synthesis.**
- **B: Phase F reuses `reviewer` agent ×N over e2e scenarios** rather than introducing a new `e2e-runner` file.
- **C: Two implementer agent files** (`implementer.md` for Opus coordinator, `implementer-worker.md` for Sonnet candidate).
- **D: Hard block** via forge-guard, not advisory.

Open in §11.

---

---

## 1. Why v2

The 1.0 system (`code-forge` + `code-forge-rig`) is a multi-agent orchestrator with a written protocol embedded in `skills/code-forge/SKILL.md`. Two failure modes drove this redesign:

1. **Protocol drift in long cycles.** Agents read the skill at session start, then forget edge cases mid-cycle. `code-forge-rig` partially fixed this with `forge-guard.mjs` hooks (348 lines of `PreToolUse`/`PostToolUse` invariants), but enforcement only covers phase ordering. Per-phase artifact correctness is still trusted, not verified.
2. **Single-evaluator review is brittle.** One evaluator agent at the end of each cycle is a single point of cognitive failure. Misses, false confidences, blind spots. Audit-grade review has solved this in the `move-pr-review` skill (sui-pilot, sketched first this week and matured over the last month) by fanning out parallel reviewers with script-mediated consolidation.

v2 merges three lines of thinking that already exist in the user's plugin tree:

- **`code-forge-rig`'s hook discipline** — phase ordering enforced as code.
- **`move-pr-review`'s script coordination** — schema-validated parallel fan-out + clustering + coverage backfill.
- **TDD as ground-truth signal** — the case made in `~/workspace/agentic-engineering-101/topics/05-tdd.md`. Tests turn agent narration into harness exit codes; with an LLM in the loop, that is the entire game.

The intended outcome: a cycle the agent cannot fake its way through. Every phase has a verifiable artifact. Every advancement gate is enforced by a script or a hook. The orchestrator's job becomes thin: run the protocol, not interpret it.

---

## 2. Non-goals

- **Not a rewrite of the planning agent** — `planner` survives unchanged. Its prompt will be lightly refined, not redesigned.
- **Not a removal of Codex cross-checks.** The Claude+Codex protocol at planning gates stays. v2 inherits it.
- **Not a generalized multi-language framework.** v2 stays opinionated about Claude Code's plugin model and the `Task` tool primitives. Portability to other agent runtimes is explicitly out of scope.
- **Not parallel implementer agents.** Implementation stays serial within a cycle. Only review fans out.

---

## 3. Foundation choice — **rig** (round-1 verdict: 2026-04-25)

### 3.1 Bench result summary

Round-1 prompt: "Implement a Sui Move counter dApp" (greenfield, ~200 LOC ceiling). Both variants ran 2 cycles, exit 0.

| Audit dimension | Original | Rig |
|---|---|---|
| Phase Completeness | 5/5 (1.0) | 5/5 (1.0) |
| Phase Ordering | 5/5 (1.0) | 5/5 (1.0) |
| Contract Compliance | 2/2 (1.0) | 2/2 (1.0) |
| Evaluation Compliance | **0/1 (0.0)** | **0/1 (0.0)** |
| Codex Gate Compliance | 5/5 (1.0) | 5/5 (1.0) |
| Iteration Discipline | 2/2 (1.0) | 2/2 (1.0) |
| Artifact Completeness | 6/6 (1.0) | 6/6 (1.0) |
| **Overall** | **0.857** | **0.857** |

**Audit verdict: tie.** Both fail Evaluation Compliance for cycle 1 (verdict "MISSING" instead of PASS) — see §11.6 for the bench-revealed protocol bug both variants share.

### 3.2 Non-audit signals favor rig

The audit measures artifact *presence*, not authenticity. Off-axis evidence:

| Signal | Original | Rig | Implication |
|---|---|---|---|
| `codex_thread_ids` in `status.md` | `{}` (empty) | `prompt_refinement` + `spec_critique` populated | **Rig actually called Codex via the bridge; original produced codex-shaped artifacts without recorded thread IDs.** Strong evidence-of-real-protocol-following advantage for rig. |
| Prompt-refinement iterations | 2 versions before final (`v1, v3`) | 5 versions before final (`v1..v5`) | Rig's hooks pushed more refinement before advancing. |
| `codebase-analysis.md` (optional artifact) | absent | present | Rig's codebase-explorer phase ran even on a greenfield prompt. |
| Project README | absent | present | Rig produced more documentation per cycle. |
| Files / LOC | 8 files / 1306 LOC | 11 files / 1557 LOC | Rig produced more output, in line with more iterations. |

### 3.3 Decision: fork `code-forge-rig`

Audit-tied + qualitative-favors-rig is the spec's "inconclusive → default to rig" branch, but more strongly: rig's `codex_thread_ids` evidence pushes this from "default" to "rig has the protocol-fidelity edge." The hooks are doing what they were built to do — preventing artifact-shape fakery — even when the audit dimension that would reward it (Codex Gate Compliance) was passed by both variants.

**v2 forks `~/workspace/dotfiles/.claude/plugins/code-forge-rig/`** as the foundation. `forge-guard.mjs` carries forward and gets extended (§8). The original plugin remains frozen for fallback and three-way bench in Phase 5.

### 3.4 Round-2 status

The round-2 (extension) bench is **deferred per §11.1 option 3** ("skip round-2; round-1 + the move-pr-review study suffices"). Three reasons make this defensible:

1. The decision rule needed "rig clearly/marginally better OR audit tie + qualitative favoring rig" to pick rig; round-1 delivered that unambiguously.
2. The script-conflict on extension prompts (§11.1) means round-2 can't be run cleanly without modifying `forge-bench.sh` or running each variant manually — engineering cost not justified by the marginal data.
3. Phase 5 of the implementation plan reruns the bench three-way (original / rig / v2) on the same prompts. That's where additional variance is collected — using v2 itself as a third data point is more informative than a second round-1.

If Phase 5 reveals foundation regret, the original is one `cp -r` away.

---

## 4. Architectural changes — the five structural shifts

### 4.1 Single thin orchestrator (was: 4 orchestrator agents)

The current preparation/planning/cycle/final-review orchestrator-per-phase agent design was the source of most protocol drift. Each agent had its own copy of the skill, paraphrased the protocol slightly differently, and accumulated divergences across cycles.

**v2 shape:** one `forge-orchestrator` agent that drives the whole flow by **invoking scripts** for phase transitions, not by reasoning about them. The orchestrator's prompt is short (~80 lines), describes the cycle phases at a high level, and points at scripts for every state machine transition. The state lives in `.forge/state.json`, not in agent memory.

This mirrors the `move-pr-review` SKILL.md design: the markdown explains the phases; the scripts implement the gates.

### 4.2 TDD as first-class cycle phase

**Old cycle:** `contract → implementation → evaluation`.

**New cycle:** `contract → test-list → red → green → consolidated-review`.

Each new phase has:
- A dedicated agent or script.
- A typed JSON artifact in `.forge/cycles/<n>/`.
- A hook in `forge-guard.mjs` that enforces the entry/exit invariants.
- A `cycle-validate.sh` rule that schema-checks the artifact before the next phase starts.

| Phase | Owner | Artifact | Forge-guard rule |
|---|---|---|---|
| `contract` | `planner` | `cycles/<n>/contract.md` | (existing rule: no implementation before contract) |
| `test-list` | `test-author` | `cycles/<n>/tests.json` (schema: `name`, `behavior`, `kind`, `target_file`) | Block writes to `src/` until `tests.json` exists and validates. |
| `red` | `test-author` | `cycles/<n>/red.log` (test runner stderr/exit code) | `PostToolUse(Bash)` after the test command checks exit ≠ 0. If 0, fail the phase — the test was tautological. |
| `green` | `implementer` | `cycles/<n>/green.log` (test runner exit code = 0) | `PreToolUse(Edit)` on test files during this phase → block. (Anti-weakening rule, from 05-tdd.md.) |
| `consolidated-review` | `reviewer` × N + `consolidator` | `cycles/<n>/_consolidated.json` + `cycles/<n>/review.md` | Cycle pass requires no `critical` clusters and `disputed_severity=true` count = 0. |

The TDD anti-patterns from the topic chapter (test-and-code in one turn, weakening assertions, post-hoc tests) become hook-enforced in green-phase, not skill-suggested.

### 4.3 Script-coordinated review fan-out

The `consolidated-review` phase replaces the single-evaluator agent with a fan-out of N parallel `reviewer` subagents, each given a different *dimension* via env var. Outputs are JSON; consolidation is a script.

**Direct port of `~/.claude/sui-pilot/skills/move-pr-review/scripts/`** (paths confirmed local at HEAD `1810524`):

| move-pr-review source | code-forge v2 analog | Adaptation |
|---|---|---|
| `validate_schema.sh` (80 lines, jq) | `cycle-validate.sh` | Same shape; categories swap to forge-cycle-relevant set (§7.1). |
| `consolidate.js` (179 lines, Node) | `cycle-consolidate.mjs` | Same clustering algorithm. STOP word list narrows further — forge cycles aren't reviewing Move/Sui code, so we drop those domain stopwords. |
| `coverage_matrix.sh` (71 lines, awk) | `cycle-coverage.sh` | Same shape; "in-scope files" derived from `cycles/<n>/contract.md`'s file list. |
| `tests/smoke.sh` (~120 lines) | `tests/smoke.sh` | New fixtures keyed to forge categories. |

**REVIEWERS default = 6** (not 10). Forge cycles have smaller surface area than PR reviews; one reviewer per dimension (§5). Tunable via env var.

**Single-turn dispatch is load-bearing.** All N `reviewer` subagents must be dispatched in one assistant message via N parallel `Agent` tool calls with `run_in_background: true`. Serial dispatch defeats the parallelism *and* the independence — agents that run in series have access to earlier outputs (via context recall) and lose review independence. The orchestrator's prompt will state this explicitly and forge-guard.mjs will detect serial dispatch via a `PreToolUse(Agent)` interceptor that fails if it sees a second reviewer dispatched after the first one has already completed.

### 4.4 Coverage-driven leader backfill

After the N reviewers complete, `cycle-coverage.sh` builds a file × reviewer matrix. Files touched by fewer than `floor` reviewers (default `floor=3` of 6, i.e. 50%) get flagged. The orchestrator then dispatches a single **leader** reviewer (R0) to backfill coverage on flagged files. Leader findings land in `subagent-0.json` and join the consolidation pass.

This counters the "subagent collusion on same blind spot" failure mode that move-pr-review's `Things that have gone wrong before` section calls out. R0 also serves as a sanity-check signal: if all 5 dimensional reviewers miss something the leader catches, that's a strong "fan-out missed it" indicator.

### 4.5 Quality gates as code, not prose

The orchestrator's job is to invoke gates, not interpret them. Every gate is a script (or a hook) that returns 0 or non-zero:

| Gate | Script | Failure action |
|---|---|---|
| Schema conformance per phase | `cycle-validate.sh` | Re-dispatch the failing agent alone, schema attached. |
| Coverage proof per cycle review | `cycle-coverage.sh` | Dispatch R0 leader backfill. |
| TDD anti-patterns (red, green, weakening) | `forge-guard.mjs` | Block the offending tool call. |
| Phase ordering | `forge-guard.mjs` (existing) | Block the offending tool call. |
| Cycle pass criteria | `cycle-pass.sh` (new) | Block cycle advancement; surface failing clusters to orchestrator. |
| **E2E pass criteria (v0.2.0)** | `cycle-e2e-pass.sh` (new) | Block ship; spawn a remediation cycle. |
| Codex cross-check at planning gate | (existing) | Re-plan or escalate. |
| **Specialist routing (v0.2.0)** | `forge-guard.mjs` PreToolUse(Task) | Block agents dispatched with mismatched `subagent_type`. |

### 4.6 Best-of-N implementer (v0.2.0)

**Old green phase:** 1 Opus implementer writes code; runs `cycle-tests-pass.sh green`; iterates until exit 0.

**New green phase:** 1 Opus **coordinator** + N **Sonnet workers** (env var `IMPLEMENTERS`, default 6).

```
green phase:
  coordinator (Opus, role=implementer)
    ├── dispatch N=6 workers in a single turn (Task ×N, run_in_background:true)
    │     │
    │     ├── worker 1 (Sonnet) — independent implementation against tests.json
    │     ├── worker 2 (Sonnet) — independent
    │     ├── ...
    │     └── worker N (Sonnet) — independent
    │
    ├── for each worker output: run cycle-tests-pass.sh green → keep passing candidates
    ├── among passing candidates: pick simplest (fewest LOC, fewest files, lowest cyclomatic)
    ├── write synthesis-notes.md documenting the choice
    └── apply chosen candidate to repo; emit green.log + green.json
```

**Pick-best, not merge.** Synthesis is *selection*, not *combining*. Fast, deterministic, debuggable. Frankenstein-merging multiple candidates risks code that no single agent produced and hides the diversity signal. If a future cycle needs merge mode, add a `--synthesize` flag; default stays pick-best.

**Forge-guard rule 5 still applies to all 11 agents.** Coordinator and all workers are blocked from editing test files in green. Test files are read-only; only `target_file` paths from `tests.json` are eligible for write.

**Diversity signal.** If all 6 workers converge on the same wrong implementation, that's information — flag it in `synthesis-notes.md` as "low diversity, likely shared blind spot." Counter (deferred to v0.3.x): re-dispatch with different prompt seeds or different model checkpoints.

### 4.7 Specialist routing + recommended-agents roster (v0.2.0)

Phase 1 emits `.forge/agent-config.md` with **two blocks**, serving different roles.

**Block 1 — `required_subagents` (hard routing, glob-based):**

```yaml
required_subagents:
  - match: "**/*.move"
    subagent_type: "sui-pilot:sui-pilot-agent"
    applies_to: [planner, implementer-worker, reviewer]
  - match: "Move.toml"
    subagent_type: "sui-pilot:sui-pilot-agent"
    applies_to: [planner, implementer-worker]
```

Hard-block enforcement (forge-guard rule 6) is reserved for **correctness-grade specialists only**. The Sui ecosystem moves fast enough that training data goes stale; Move review by a non-sui-pilot agent has a high false-confidence risk. That's a correctness concern, not a taste concern, so it's a hard rule.

Frontend specialists (impeccable, etc.) and other quality-preference plugins live in **Block 2 (recommended_agents)**, not here. Forcing impeccable on every `.tsx` would over-constrain — general-purpose agents write competent React; impeccable just makes it nicer. The soft roster preserves the favoritism without making non-impeccable frontend impossible.

Skips when no `agent-config.md` exists, or when no `required_subagents` entry matches the cycle scope (greenfield without Sui content).

**Block 2 — `recommended_agents` (soft roster, curated from user's enabled set):**

```yaml
recommended_agents:
  - subagent_type: "sui-pilot:sui-pilot-agent"
    rationale: "Primary Sui/Move specialist; user-favored."
    suitable_for: [planner, test-author, implementer, reviewer]
    domain_relevance: high   # high | medium | low
  - subagent_type: "impeccable:impeccable-agent"
    rationale: "Frontend specialist; user-favored for UI work."
    suitable_for: [implementer-worker, reviewer]
    domain_relevance: medium
  - subagent_type: "superpowers:test-driven-development"
    rationale: "Cross-cutting TDD discipline; user-favored."
    suitable_for: [test-author, implementer]
    domain_relevance: high
```

**How the planner builds the roster:**

1. Enumerate `enabledPlugins` from `~/.claude/settings.json` and the agent definitions exposed by each enabled plugin.
2. Filter by relevance to the spec's target files / domain markers (Sui? frontend? CLI?).
3. **User-favoritism layer:** if any of the following plugins are enabled, surface their agents *first* in the roster regardless of secondary scoring — `sui-pilot`, `impeccable`, `superpowers/*`. (User-level preference; see project memory `project_forge_preferred_agents.md`.)
4. Output the roster ordered by `domain_relevance` desc, then by user-favoritism, then by name.

**How the orchestrator uses the roster:**

When dispatching a Task call for any role (planner subagent for the contract phase, implementer-worker, reviewer dimension, etc.), prefer agents from `recommended_agents[*]` whose `suitable_for` includes the role and whose `domain_relevance` is `high`. Fall back to `medium` then to general-purpose. The `required_subagents` block still hard-overrides — required wins over recommended on conflict.

**Why two blocks, not one:** required is for correctness (you cannot review Move code well without Sui knowledge); recommended is for quality (the user has trusted plugins; favoring them increases the chance of good output). Conflating them would either over-block (refusing a Move review by general-purpose when sui-pilot isn't installed) or under-enforce (treating routing as a suggestion when it's actually a correctness requirement).

### 4.7.2 Project-domain compound routing (v0.2.0, decided 2026-04-26)

The file-glob rules in Block 1 catch *which file* an agent is editing. They do NOT catch *what project the agent is part of*. A TypeScript file in a Sui dApp project is still Sui-context work — the agent touching it should know about dapp-kit, wallet adapters, on-chain RPC patterns, and so on, even though `*.ts` doesn't trigger the Move-file glob.

The fix is a higher-level marker.

**`agent-config.md` gains a top-level `project_domains` field:**

```yaml
project_domains:
  - sui-dapp        # any of: sui-dapp, walrus, seal, sui-cli, etc.
  # - frontend     # not a hard-routing trigger by default — see below
```

**Hard rule (forge-guard rule 6 extension):** when `project_domains` contains `sui-dapp`, **every** Task dispatch in the run — planner, codebase-explorer, test-author, implementer, every implementer-worker, every reviewer dimension, consolidator — uses `subagent_type = "sui-pilot:sui-pilot-agent"`. No exceptions for non-Move files. The forge-guard rule rejects Task calls whose `subagent_type` isn't `sui-pilot:sui-pilot-agent` while `sui-dapp` is in `project_domains`.

**Role behavior is delivered via prompt, not subagent_type.** The role-specific instructions in `agents/test-author.md`, `agents/implementer.md`, `agents/reviewer.md`, etc. become *role-prompt templates* the orchestrator embeds in the Task call's `prompt` parameter. The dispatched agent is sui-pilot; what it does this turn is shaped by the embedded role prompt.

```
# Conceptually, every dispatch when project_domains contains sui-dapp:
Task(
  subagent_type: "sui-pilot:sui-pilot-agent",
  prompt: f"""
    {render_role_prompt('test-author', cycle=2)}

    [+ usual cycle context: contract.md, tests.json, etc.]
  """
)
```

**Why this beats per-glob enforcement.** A pure-file-glob rule for `*.move` doesn't catch the SDK code in `src/sui-client.ts`, but that code is also Sui-context and needs sui-pilot's live-doc awareness. A project-domain marker is the right granularity for "this whole run is Sui work."

**How `recommended_agents` interacts with project_domain.** The soft roster still informs **prompt composition**, not dispatch. When project_domain forces sui-pilot as the subagent_type, the orchestrator can still inject guidance from recommended agents into the prompt — e.g. "you are sui-pilot acting as implementer-worker; apply superpowers' TDD discipline as you write code." The roster's `recommended_agents` entries become prompt-fragment hints rather than dispatch routing decisions.

**Frontend in a Sui dApp:** impeccable stays in `recommended_agents` (favorited) but does NOT override the project-domain dispatch. A `.tsx` file in a Sui dApp run is touched by sui-pilot, with impeccable's design sensibilities injected into the prompt: "act as sui-pilot but apply impeccable's frontend design discipline." This satisfies the user's "every agent should be sui-pilot on top of any other agent it should be" requirement without requiring two simultaneous subagent_types (which Claude Code's Task tool doesn't support).

**How the planner sets `project_domains`.** During Phase 1, the planner inspects:
- `Move.toml` presence → `sui-dapp`
- `@mysten/sui` or `@mysten/dapp-kit` in `package.json` → `sui-dapp`
- `walrus.toml` or `walrus_storage` types → `walrus`
- `seal_id` types or seal-specific dependencies → `seal`
- Mixed: a project can be tagged `sui-dapp + walrus` simultaneously, in which case sui-pilot still applies (the agent already knows all three ecosystems via its embedded doc index).

**When project_domain is empty.** Phase 1 omits the `project_domains` field. forge-guard rule 6 falls back to the per-glob rules in Block 1. General-purpose orchestration applies.

### 4.7.1 Phase 1 internal flow — Codex iteration loops

Phase 1 isn't a single drafting pass; it's **two Codex-iterated loops** to ensure the spec and the e2e tests are coherent end-to-end with the plan.

```
Phase 1 internal flow (orchestrator):

  step 1a — planner reads plan.md, drafts spec.md (without ## E2E Tests)
  step 1b — Codex G2.a: "does this spec satisfy plan.md?"
                              ↓
                              ├─ AGREE → continue
                              └─ DISAGREE → planner revises spec; loop step 1b (cap=3)
  step 1c — planner adds ## E2E Tests section to spec.md
  step 1d — Codex G2.b: "do these e2e tests cover the spec's acceptance criteria?"
                              ↓
                              ├─ AGREE → continue
                              └─ DISAGREE → planner revises e2e (or spec); loop step 1d (cap=3)
  step 1e — planner enumerates enabled plugins, generates agent-config.md
              (recommended_agents + required_subagents blocks)
  step 1f — phase exits; spec.md + agent-config.md are sealed
```

The two loops are **separate** so each has a clear question Codex can answer with a binary verdict + targeted feedback. Conflating them ("does this whole thing work?") produces vague critiques. Splitting them ("plan→spec coherent?" then "spec→e2e coherent?") makes failure modes localizable.

**Retry cap = 3 per loop.** After cap, escalate to user with the disagreement summary. The user can override (accept the spec as-drafted) or amend the plan/spec themselves.

### 4.8 E2E tests as cross-cycle invariant (v0.2.0)

The v0.1.0 design had unit/integration TDD inside each cycle but **no cross-cycle integration check**. Cycles 1, 2, 3 could each pass their own review while still failing to compose into a working product. v0.2.0 closes this gap.

**Where e2e tests live:**
- `spec.md` MUST contain a `## E2E Tests` section with named scenarios (Gherkin-ish or structured).
- The cycle-plan.md references which e2e scenarios each cycle brings online (entry-point status: stub, mock, real).
- A new artifact `.forge/e2e/scenarios.json` is derived from spec.md by the planner; same shape as `tests.json` but at product level, not unit level.

**Phase F — e2e-review (post-cycles):**
- Triggered after the last cycle's `consolidated-review` passes.
- Reuses the `reviewer` agent definition, dispatched ×N over scenarios (one reviewer per scenario family). Each reviewer:
  - Reads the e2e scenario(s) it owns.
  - For frontend products: drives Chrome via `chrome-devtools-mcp:chrome-devtools` skill — navigates the deployed/local app, exercises the user flow, captures screenshots + DOM state.
  - For CLI/API products: runs the e2e harness directly.
  - Emits findings in the same schema as cycle reviewers, but `category` may include a new `e2e-flow` value.
- A consolidator pass (same `consolidator` agent) synthesizes `.forge/e2e/_consolidated.json` and `.forge/e2e/review.md`.
- New gate: `cycle-e2e-pass.sh` — exit 0 iff e2e-review consolidated artifact has no critical clusters AND every scenario has at least one passing reviewer touch.

**Failure → remediation cycle.** If e2e-review fails, the orchestrator does NOT loop back inside the same phase. It spawns a new cycle (cycles/N+1) with a contract derived from the e2e failures: "fix the integration gaps that made scenarios X, Y fail." That cycle goes through the full TDD loop. Then re-run Phase F. Cap at 3 remediation cycles before escalating to user.

**When to skip Phase F.** If `spec.md` has no `## E2E Tests` section (single-cycle deliverables, library-internal tasks), skip. Forge-guard's prerequisite check warns if e2e is absent and cycle-plan has more than one cycle — strong signal that cross-cycle integration was assumed but not verified.

### 4.9 Compressed pre-cycle phases (v0.2.0)

Old: 7 pre-cycle phases (intent, exploration, prompt-refinement, agent-detection, specification, spec-critique, cycle-planning).

New: 3 pre-cycle phases.

| New phase | What | Replaces |
|---|---|---|
| **Phase 0 — Plan** | Codex refines the lazy prompt → Claude in plan mode → AskUserQuestion to clarify uncertainties → user-approved plan written to `.forge/plan.md`. Wraps `codex-bridge:claudex` skill. Big-scope-aware: clarify what matters at this level, defer what's better decided during implementation. Codex G1 cross-check is intrinsic to claudex's multi-round refinement. | intent + prompt-refinement + exploration (the explorer is dispatched from inside the plan flow when the prompt is "extend an existing repo") |
| **Phase 1 — Spec & e2e** | Planner takes `plan.md`, drafts `spec.md` *with required `## E2E Tests` section*, detects domain markers, enumerates the user's currently-enabled agents, writes `agent-config.md` with both `required_subagents` (hard routing) and `recommended_agents` (soft roster). **Two Codex iteration loops** in this phase, both bounded by a retry cap: G2.a "does the spec satisfy `plan.md`?" → revise spec until agree; G2.b "do the e2e tests in `## E2E Tests` cover the spec's acceptance?" → revise tests until agree. | specification + spec-critique + agent-detection (combined) |
| **Phase 2 — Cycle plan** | Break spec into cycles. Each cycle's entry references which e2e scenarios it brings online. Codex G2.5 cross-check on the cycle plan. | cycle-planning (augmented with e2e-coverage tracking) |

The compression is justified because the old phases had overlapping concerns and produced overlapping artifacts; merging reduces context-switch cost and eliminates inter-phase staleness. The Codex gates G1 and G2 land at natural inflection points (plan→spec, spec→cycle-plan), preserving the cross-check discipline.

**Pre-cycle becomes effectively three artifacts:** `plan.md`, `spec.md` (with e2e), `cycle-plan.md`. forge-orchestrator dispatches one agent per phase, gates each transition with `cycle-validate.sh`.

---

## 5. Agent hierarchy

Reduced from 8 agents (v1) to 7 stable agent files in v0.1.0 → **8 stable agent files in v0.2.0** (added `implementer-worker.md`) + N reviewer instances + N implementer-worker instances per green phase:

| Agent | Replaces | Purpose | Dispatched as | Parallelism |
|---|---|---|---|---|
| `forge-orchestrator` | preparation- + planning- + cycle- + final-review-orchestrators | Drives the cycle by invoking scripts; never reasons about phase order. | Main session only (cannot be a spawned subagent — Task tool needed). | Singleton. |
| `planner` | `planner` (light refinement) | Spec → contract. Codex cross-checked at planning gate. | Foreground subagent. | Singleton per cycle. |
| `codebase-explorer` | `codebase-explorer` (unchanged) | Pre-spec phase only. Indexes existing repo for the planner. | Foreground subagent. | 1–3 in parallel. |
| `test-author` | (new) | Owns `test-list` and `red` phases. Emits `tests.json` then test code, runs red. | Foreground subagent. | Singleton per cycle. |
| `implementer` (Opus) | `implementer` (now coordinator) | Owns the `green` phase **as a coordinator** in v0.2.0. Dispatches N=IMPLEMENTERS Sonnet workers in a single turn; runs each candidate against `cycle-tests-pass.sh green`; picks the simplest that passes; writes synthesis-notes.md. Cannot edit test files. | Foreground subagent (Opus). | Singleton per cycle. |
| `implementer-worker` (Sonnet, **v0.2.0 new**) | (new file) | One independent candidate implementation per worker. Reads contract + tests; produces source diffs against the same target files. Each worker is independent — does not see other workers' output. Cannot edit test files. | Background subagent (Sonnet) via Task ×N in a single turn. | N=IMPLEMENTERS (default 6) per cycle. |
| `reviewer` | `evaluator` (generalized) | One dimension per instance, dispatched in parallel during `consolidated-review`. **In v0.2.0 also reused in Phase F (e2e-review)**, dispatched ×N over e2e scenarios with `MODE=e2e` env var. | Background subagent. | N (default 6) per cycle review; ×scenarios for e2e. |
| `consolidator` | (new, separate file) | Synthesizes `_consolidated.json` into review.md. Verifies critical/high clusters against source. Splits mega-clusters. **In v0.2.0 also runs for Phase F** (synthesizes e2e reviewer outputs). | Foreground subagent. Own agent definition file (no env-var prompt branching). | Singleton per cycle; singleton for Phase F. |

`final-review-orchestrator` is gone. Its job is the last cycle's `consolidated-review` invoked against the full deliverable, not a separate phase.

`reviewer.md` and `consolidator.md` are **separate files** (not one file with prompt-branching on an env var). Cleaner separation; the small boilerplate cost is paid back in readability and the ability to evolve the consolidator's verification heuristics independently of the dimensional review prompt.

**`reviewer` dimensions** (one per `REVIEWER_DIMENSION` env var value, dispatched in parallel):

1. `correctness` — does the code do what tests/contract say?
2. `design` — coherence, separation of concerns, naming, file boundaries.
3. `error-handling` — silent failures, missing error paths, fallback hazards (cf. `pr-review-toolkit:silent-failure-hunter` for prompt).
4. `simplicity` — accidental complexity, premature abstraction, dead code.
5. `tests-vs-impl` — do the tests actually exercise the implementation, or are they tautological?
6. `security` — real vulnerability classes (auth gaps, input validation, capability leaks). Especially load-bearing on Sui/Move and crypto-adjacent work, where v2 is most likely to be used.

REVIEWERS=6 maps 1:1 to these dimensions. If REVIEWERS is overridden to a different number, dimensions are sampled with replacement (with a deterministic seed for reproducibility).

**Dispatch model — read §15 before treating any agent in this table as interchangeable.** Every agent above is dispatched as an *in-process subagent* via the `Task` tool. There is a second dispatch mode — fresh `claude` CLI sessions in tmux panes, the way `forge-bench` does it — that has different properties (interactive, AskUserQuestion-capable, isolated context). §15 catalogs the cycle stages where the second mode would earn its place. None of those are committed for v2 day-one, but the section names them so a future iteration can adopt the pattern without re-deriving the rationale.

---

## 6. Cycle protocol — the artifact tree

Every cycle produces `.forge/cycles/<n>/` with this fixed structure:

```
.forge/
├── state.json                     # Orchestrator's state machine (phase, gate status)
├── prompt.txt                     # Original lazy prompt
├── plan.md                        # v0.2.0: Phase 0 output (claudex flow)
├── spec.md                        # v0.2.0: Phase 1 output, includes ## E2E Tests section
├── agent-config.md                # v0.2.0: required_subagents bindings (Phase 1)
├── cycle-plan.md                  # Phase 2 output
├── codebase-index.md              # If extension prompt: codebase-explorer output (now from Phase 0)
├── cycles/
│   └── <n>/                       # One directory per cycle (n = 1, 2, ...)
│       ├── contract.md            # Planner output for this cycle
│       ├── tests.json             # test-author Phase test-list output (schema-validated)
│       ├── red/
│       │   ├── *.test.ts          # The actual failing tests
│       │   └── red.log            # Test runner output proving they fail
│       ├── green/
│       │   ├── candidates/        # v0.2.0: best-of-N implementer artifacts
│       │   │   ├── worker-1/      # Worker 1's diffs + tests-pass exit code
│       │   │   ├── worker-2/
│       │   │   └── ...worker-N/
│       │   ├── synthesis-notes.md # v0.2.0: coordinator's pick-best reasoning
│       │   ├── (chosen implementation files in their normal locations)
│       │   └── green.log          # Test runner output proving green
        ├── reviewers/
        │   ├── subagent-1.json    # correctness reviewer findings
        │   ├── subagent-2.json    # design reviewer findings
        │   ├── subagent-3.json    # error-handling reviewer findings
        │   ├── subagent-4.json    # simplicity reviewer findings
        │   ├── subagent-5.json    # tests-vs-impl reviewer findings
        │   └── subagent-0.json    # leader backfill (if coverage_matrix flagged)
│       ├── _consolidated.json     # consolidate.mjs output
│       ├── _coverage_matrix.txt   # coverage_matrix.sh output
│       ├── _verification_notes.md # consolidator's adjudications
│       └── review.md              # Final cycle review
└── e2e/                           # v0.2.0: Phase F (post-cycles) artifacts
    ├── scenarios.json             # extracted from spec.md ## E2E Tests
    ├── reviewers/                 # one reviewer per scenario, MODE=e2e
    │   ├── subagent-1.json
    │   └── ...subagent-N.json
    ├── _consolidated.json         # cycle-consolidate.mjs output (reused)
    ├── _verification_notes.md     # consolidator (reused, MODE=e2e)
    └── review.md                  # Final e2e review; gates ship via cycle-e2e-pass.sh
```

Phase advancement requires:
1. Previous phase's artifact present and schema-valid (`cycle-validate.sh`).
2. Forge-guard.mjs rules satisfied for the transition.
3. (For `consolidated-review` exit only) `_consolidated.json` has 0 `critical` clusters and 0 `disputed_severity=true` clusters.

If a gate fails, the orchestrator:
- Re-dispatches the responsible agent with the failure feedback attached.
- Increments a per-phase retry counter in `state.json`.
- Caps retries at 3 per phase. After cap, escalates to user.

---

## 7. Schemas

### 7.1 Reviewer finding schema (per-element of `subagent-N.json`)

Direct port of move-pr-review's `references/finding_schema.md`, with categories tailored to forge cycle review:

```json
{
  "id": "R3-007",                                    // R<N>-NNN, N is reviewer number
  "title": "Promise rejection swallowed in formatJsonOutput",
  "severity": "high",                                // critical | high | medium | low | info
  "category": "error-handling",                      // see allowed list below
  "file": "src/sloc.ts",
  "line_range": "84-99",
  "description": "When formatJsonOutput() encounters an unparseable file, the .catch() handler returns null without logging or surfacing the error path.",
  "impact": "Silent data loss for malformed inputs. CLI exits 0 even when half the input set failed to read.",
  "recommendation": "Replace .catch(() => null) with logging + counting; return a structured result with both successes and failures.",
  "evidence": ".catch(() => null)",
  "confidence": "high"                               // high | medium | low
}
```

**Allowed categories for forge cycle review:**
- `correctness`
- `design`
- `error-handling`
- `simplicity`
- `tests-vs-impl`
- `dependencies`        — version pins, lockfile, transitive risk
- `security`            — scoped narrowly: real vulnerability classes, not "could be more defensive"
- `performance`         — only when concretely measurable, not micro-optimization vibes
- `documentation`       — comments and READMEs
- `build`               — compile/build script issues

**Severity rubric (same wording as move-pr-review):**

| Severity | Definition |
|---|---|
| critical | Security vulnerability, data loss, or contract violation that ships if merged. |
| high     | Bug or design flaw the user will hit in normal use. |
| medium   | Bug or design flaw under unusual but plausible conditions. |
| low      | Stylistic, minor, or edge-case finding. |
| info     | Observation, future-proofing note, no action implied. |

### 7.2 Cluster schema (`_consolidated.json` element)

Same shape as move-pr-review's. No changes:

```json
{
  "cluster_id": "C001",
  "title": "Promise rejection swallowed in formatJsonOutput",
  "file": "src/sloc.ts",
  "line_ranges": ["84-99", "85-92"],
  "agreement_count": 3,
  "reviewers": [1, 3, 5],
  "max_severity": "high",
  "min_severity": "medium",
  "disputed_severity": false,
  "categories": ["error-handling", "correctness"],
  "recommendations": ["..."],
  "descriptions": ["..."],
  "impacts": ["..."],
  "evidence": "the longest evidence quote across cluster members",
  "confidence_spread": ["high", "medium"],
  "source_ids": ["R1-004", "R3-007", "R5-002"]
}
```

### 7.3 Test-list schema (`tests.json`)

```json
[
  {
    "id": "T-001",
    "name": "counts zero lines for an empty directory",
    "behavior": "sloc(emptyDir) returns 0 with no warnings",
    "kind": "unit",                            // unit | integration | property
    "target_file": "src/sloc.ts",
    "covers_contract_requirement": "R1.2"      // refs contract.md anchor
  }
]
```

`tests.json` is reviewed and pruned by the orchestrator (or, optionally, by a Codex cross-check) before `red` phase begins.

### 7.4 E2E scenarios schema (`e2e/scenarios.json`, v0.2.0)

```json
[
  {
    "id": "E-001",
    "name": "user signs in and sees their counter",
    "kind": "ui",                                  // ui | api | cli
    "preconditions": ["app running on localhost:3000", "test user fixture"],
    "steps": [
      "navigate to /sign-in",
      "fill #email with 'test@example.com'",
      "click button:has-text('Sign in')",
      "wait for url '/dashboard'",
      "assert text 'Counter: 0' visible"
    ],
    "expected": "Dashboard loads showing zero counter for new user",
    "covers_contract": ["R1.1", "R3.2"],           // refs spec.md / cycle-plan.md
    "tooling": "chrome-devtools-mcp"               // null for cli/api
  }
]
```

Validated by `cycle-validate.sh` like other schemas. The `tooling` field tells the e2e reviewer (in Phase F) which MCP server to invoke for execution.

### 7.5 Agent-config schema (`agent-config.md` frontmatter, v0.2.0)

YAML frontmatter at the top of `agent-config.md` (followed by free-text discussion of the routing decisions). **Two blocks**, both required when `agent-config.md` exists:

```yaml
---
project_domains:
  - sui-dapp        # when present, sui-pilot:sui-pilot-agent is dispatched for
                    # ALL Task calls in this run regardless of file. Role
                    # behavior delivered via prompt injection. See §4.7.2.

required_subagents:
  - match: "**/*.move"
    subagent_type: "sui-pilot:sui-pilot-agent"
    applies_to: [planner, implementer-worker, reviewer]
  - match: "Move.toml"
    subagent_type: "sui-pilot:sui-pilot-agent"
    applies_to: [planner, implementer-worker]
  # Note: only correctness-grade specialists go here. Quality-preference
  # plugins like impeccable for frontend live in recommended_agents below.
  # When project_domains contains sui-dapp, these glob rules are subsumed
  # (sui-pilot is forced for everything) but kept here as fallback for
  # mixed/non-tagged projects.

recommended_agents:
  - subagent_type: "sui-pilot:sui-pilot-agent"
    rationale: "Primary Sui/Move specialist; user-favored."
    suitable_for: [planner, test-author, implementer, reviewer]
    domain_relevance: high
  - subagent_type: "impeccable:impeccable-agent"
    rationale: "Frontend specialist; user-favored for UI work."
    suitable_for: [implementer-worker, reviewer]
    domain_relevance: medium
  - subagent_type: "superpowers:test-driven-development"
    rationale: "Cross-cutting TDD discipline; user-favored."
    suitable_for: [test-author, implementer]
    domain_relevance: high
  - subagent_type: "superpowers:verification-before-completion"
    rationale: "Cross-cutting evidence-before-claims discipline."
    suitable_for: [implementer, consolidator]
    domain_relevance: medium
---
```

**`required_subagents`** — hard glob-based routing. Enforced by forge-guard rule 6.

**`recommended_agents`** — soft curated roster. Built by the planner from the user's `enabledPlugins` set, filtered by domain relevance, with explicit favoritism for the user's preferred plugins (sui-pilot, impeccable, superpowers/\*). Used by the orchestrator as a dispatch preference, not a constraint.

`applies_to` and `suitable_for` scope each entry: a Sui binding may want to enforce on planner/implementer-workers but leave reviewers free to pick general-purpose dimensions. Default if `applies_to`/`suitable_for` is omitted: all roles.

`domain_relevance` is one of `high | medium | low`. The orchestrator dispatches `high` first, falls through to `medium`, then to general-purpose if neither is suitable.

---

## 8. Hook additions to `forge-guard.mjs`

The current rig hook (`code-forge-rig/hooks/forge-guard.mjs`, 348 lines) covers phase ordering. v2 adds TDD discipline and review-fan-out invariants. **Carry forward, don't rewrite.**

New rules to add:

1. **`PreToolUse(Edit)` test-file-during-green block** — match path against `tests.json` `target_file`s; reject if current phase is `green` and the editing agent isn't `test-author`.
2. **`PostToolUse(Bash)` red-phase exit-code requirement** — when in `red` phase and command was the test runner, require exit code ≠ 0. If 0, mark phase failed and re-dispatch test-author with feedback "tests passed at red, are they tautological?"
3. **`PreToolUse(Agent)` parallel-fan-out enforcement** — during `consolidated-review`, if a `reviewer` Agent call is dispatched more than 5 seconds after a previous `reviewer` Agent call has completed (rather than co-issued in the same turn), reject. Pushes orchestrator to dispatch all reviewers in one turn.
4. **`PreToolUse(Edit)` post-cycle-pass freeze** — after a cycle's `_consolidated.json` is sealed (no critical, no disputed), block edits to files mentioned in that cycle's `contract.md` until next cycle's `contract` phase begins. Prevents implementer-after-review drift.
5. **`PostToolUse(Edit)` cycle-validate fire** — after edits to `tests.json`, `contract.md`, or any `subagent-*.json`, run `cycle-validate.sh` against that file synchronously. Block on fail.
6. **`PreToolUse(Task)` specialist routing (v0.2.0)** — read `agent-config.md`'s `required_subagents` block. For each Task call dispatched during a phase whose contract scope (or worker target file) matches a `match` glob, require `subagent_type` to equal the binding's value. Hard-block mismatches. Effect: a Sui cycle dispatched without a sui-pilot specialist is impossible; the orchestrator's only path forward is to pass the right subagent_type. Skips when no `agent-config.md` exists (greenfield, no specialist needed).
7. **`PreToolUse(Task)` implementer-worker fan-out (v0.2.0)** — during `green` phase, if a second `implementer-worker` Task call is dispatched >5s after a previous worker's output already exists, block. Same single-turn-dispatch enforcement as the reviewer rule, applied to the green-phase fan-out.
8. **`PreToolUse(Edit)` test-file-during-green extends to all 11 agents (v0.2.0)** — rule 1 above still applies, but now matches against the implementer coordinator AND every implementer-worker. Test files are read-only in green for the entire 1+N agent family.

All advisory (non-blocking) rules from rig stay advisory. The blocking rules above are non-negotiable.

---

## 9. Scripts to write

Co-located with the v2 plugin: `~/workspace/dotfiles/.claude/plugins/code-forge-v2/scripts/`.

| Script | Lines (estimate) | Notes |
|---|---|---|
| `cycle-validate.sh` | ~100 | Port of `validate_schema.sh`. Categories list from §7.1. Add validators for `tests.json` and `contract.md` (the latter checks for required H2 headings). |
| `cycle-consolidate.mjs` | ~200 | Port of `consolidate.js`. Adjust STOP wordlist (drop sui/move terms; add forge-internal terms `cycle`, `forge`, `phase`). Same clustering math. |
| `cycle-coverage.sh` | ~80 | Port of `coverage_matrix.sh`. `floor=3` of 5. In-scope file list from `contract.md`. |
| `cycle-pass.sh` | ~50 | New. Reads `_consolidated.json`. Returns 0 iff: `critical` count = 0 AND `disputed_severity=true` count = 0. Prints failing clusters on non-zero exit. |
| `cycle-tests-pass.sh` | ~30 | New. Wrapper around the project's test command. Surfaces exit code + parsed pass/fail counts to `green.log` / `red.log`. |
| `cycle-init.sh` | ~60 | New. Scaffolds `cycles/<n>/` at the start of each cycle with empty schema-valid stubs (placeholder `contract.md`, empty-array `tests.json`, empty `reviewers/` directory). Prevents orchestrator drift on artifact tree shape — the directory is always in a known state when a phase agent starts work. |
| `forge-status.sh` | ~80 | New. Reads `.forge/state.json` and `cycles/*` and prints a human-readable progress dashboard: current phase, cycles completed, gate failures, retry counters. Useful when an interactive session has scrolled past the orchestrator's last status update; user can run it any time to ground their mental model. |
| `tests/smoke.sh` | ~150 | CI gate. Fixtures: a known-good cycle artifact tree under `tests/fixtures/`. Asserts: `cycle-validate.sh` accepts it, `cycle-consolidate.mjs` produces expected clusters, `cycle-coverage.sh` flags expected files, `cycle-pass.sh` returns expected verdict. Runs in <30s. |
| `tests/fixtures/cycle-good/` | (data) | A passing cycle artifact tree. |
| `tests/fixtures/cycle-bad-disputed/` | (data) | A cycle with a disputed cluster — must fail `cycle-pass.sh`. |
| `tests/fixtures/cycle-bad-tautological-test/` | (data) | A red phase where tests passed — must fail forge-guard's red-phase rule. |
| `cycle-e2e-pass.sh` (v0.2.0) | ~80 | New. Reads `e2e/_consolidated.json` + `e2e/scenarios.json`. Exit 0 iff: 0 critical clusters AND every scenario has at least one passing reviewer touch. Failure mode triggers a remediation cycle (orchestrator spawns a new `cycles/<n+1>/` with contract derived from e2e gaps). |
| `e2e-extract.sh` (v0.2.0) | ~50 | New. Parses `spec.md`'s `## E2E Tests` section and emits `e2e/scenarios.json`. Run at the start of Phase F. |
| `tests/fixtures/cycle-good-with-best-of-n/` (v0.2.0) | (data) | Cycle with `green/candidates/worker-1..6/` and `synthesis-notes.md`. Asserts coordinator picked the simplest candidate. |
| `tests/fixtures/e2e-good/` (v0.2.0) | (data) | A passing e2e review tree under `e2e/`. |

---

## 10. Migration plan

### 10.1 Foundation fork

After bench (§3), create `~/workspace/dotfiles/.claude/plugins/code-forge-v2/` from chosen source. New `plugin.json` with name `code-forge-v2`, version `0.1.0`. Old plugins frozen for fallback and three-way bench.

### 10.2 Agent prompt port

Port the 8 existing agent prompts into the new 7-agent shape:

- `planner.md` → `planner.md` (light refinement)
- `implementer.md` → `implementer.md` (add: cannot edit test files in green phase)
- `evaluator.md` → splits into `reviewer.md` (one prompt, dispatched ×N with `REVIEWER_DIMENSION` env var) + `consolidator.md` (separate file with its own prompt — verification heuristics, mega-cluster splitting, final report shape)
- `codebase-explorer.md` → `codebase-explorer.md` (unchanged)
- `cycle-orchestrator.md` + `planning-orchestrator.md` + `preparation-orchestrator.md` + `final-review-orchestrator.md` → `forge-orchestrator.md` (compressed)
- (new) `test-author.md`
- (new) `consolidator.md` (split from the old evaluator)

Most prose carries forward. The orchestrator prompt is the heaviest compression — it goes from ~900 lines distributed across 4 files to ~80 lines + pointers to scripts.

### 10.3 SKILL.md rewrite

`skills/code-forge/SKILL.md` becomes a high-level cycle description + a script index, not a procedural manual. Same shape as `move-pr-review/SKILL.md`. Target ~250 lines (from current ~600).

### 10.4 Hook port

Copy `code-forge-rig/hooks/forge-guard.mjs` into v2. Add the five new rules from §8. Run move-pr-review's smoke-test pattern on the hook.

### 10.5 Smoke tests — CI primary + manual `/forge-smoke`

`tests/smoke.sh` is the v2 plugin's self-test. Two enforcement points:

1. **CI primary.** A GitHub Actions workflow at `.github/workflows/forge-smoke.yml` (in the dotfiles repo) runs `bash plugins/code-forge-v2/tests/smoke.sh` on every push and pull request. Failures block merge.
2. **On-demand local check.** A `/forge-smoke` slash command (defined at `commands/forge-smoke.md`) runs the same script locally. Use before pushing changes — catches issues introduced by uncommitted local edits that CI hasn't seen yet.

**No SessionStart hook.** That option was considered and rejected: every Claude Code session would pay ~30s startup cost whether or not v2 is used in that session. The CI-primary architecture catches breakage on the merge boundary (where it matters most) and the slash command covers the local-edit gap. Lower friction, same correctness guarantee on what reaches the plugin tree.

This is TDD applied to the plugin itself — the plugin's tests come before the plugin is run on real cycles.

---

## 11. Open questions / deferred decisions

### 11.0 In-process subagents vs fresh CLI sessions — a future-use lever

**The architectural distinction.** Two things that look the same in casual writing are *not* the same in this system:

| | In-process subagent (Agent tool) | Fresh CLI session in tmux pane |
|---|---|---|
| Lifecycle | Reasoning thread inside parent process | Separate `claude` CLI invocation, own process |
| Stdin/stdout | None — result returned as tool message | Full interactive TTY |
| AskUserQuestion | Cannot pause for user input | Works |
| Context | Bounded prompt, parent's plugin set, no parent state | Loads user-level config; does NOT inherit parent's transient state |
| Visibility to user | Status line only; output appears at end | Live, in a tmux pane |
| Real independence | Shares the parent's model + reasoning conditioning | Genuinely separate session — counters blind-spot collusion |
| Cost | Cheap (one prompt) | Heavier (full session boot, plugin loads) |

forge-bench works because it sidesteps the Agent tool entirely and uses `bash` + `tmux` + `claude` CLI as the orchestration substrate. That is a different architecture, not a Claude Code feature you can flip on.

**Why this matters for v2.** Most of v2's parallelism (the 5-way reviewer fan-out, the codebase-explorer dispatch) is well-served by in-process subagents — they're cheap, they inherit the orchestrator's plugin set, and we don't need user input mid-review. But there are stages of the cycle where a **fresh CLI session reading artifacts** would be strictly better than another in-process subagent:

| Cycle stage | Why fresh-session would help |
|---|---|
| Final cycle-pass judgment | Reads `contract.md`, `_consolidated.json`, `review.md` cold. No prior reasoning to anchor on. Counters "consolidator + parent share blind spots." |
| Planning-gate validation | Reads `plan.md` and `codebase-index.md` cold and answers "does this contract actually correspond to the user's prompt?" Pairs naturally with the existing Codex cross-check. |
| Leader (R0) smoke-read | The orchestrator's private smoke-read of cycle deliverables (§4.4 / §13). A fresh session reading the same files the reviewers see is the cleanest "outside view." |
| Final review at end of `/forge` run | Replaces `final-review-orchestrator`. A fresh session reads the entire `.forge/` tree and the deliverable, emits a verdict. AskUserQuestion is available here for real interactive sign-off. |

**Three ambition levels for wiring this.** Captured for later evaluation; **none chosen for v2 0.1**:

1. **Full replacement (most ambitious).** A `PreToolUse(Agent)` hook intercepts every Agent call, spawns an interactive `claude` session in a tmux pane with the same prompt, waits via `tmux wait-for`, captures the pane's output, substitutes it as the Agent tool's result. Risk: changes semantics of every multi-agent skill in the install (move-pr-review, code-review, etc.) — some assume parent state inheritance. Possibly slow due to per-call session boot cost. Tooling: `update-config` skill + `plugin-dev:hook-development` skill.
2. **Selective via skill (middle ground — Recommended for v2 evaluation).** Add a custom skill like `/dispatch-fresh <prompt-file>` that the forge-orchestrator can invoke at the four stages above. Other multi-agent workflows are unchanged. The forge cycle gets the benefit at the points where it's most load-bearing.
3. **Mirror only (post-hoc).** A `PostToolUse(Agent)` hook spawns a read-only display pane after the in-process subagent completes. Useful for visibility but not for AskUserQuestion or independent reasoning. Lowest implementation cost; lowest payoff.

**Decision deferred.** v2 0.1 ships with in-process subagents throughout. After three real cycles, if the orchestrator's "leader smoke-read" or the final cycle-pass judgment shows signs of parent-context contamination (consolidator agreeing with reviewers it should challenge, or final-review missing what the orchestrator missed), upgrade those specific stages to fresh-session via path 2.

**Why not now.** v2 has enough moving parts already. Layering a session-boundary architectural change on top of TDD-as-phase, script coordination, hook discipline, and a bench-driven foundation pick risks coupling several axes of failure. Ship the boring version first, instrument it, measure the failure modes, then introduce fresh sessions where they earn their keep.

### 11.1 Round-2 (extension) bench

The forge-bench script `auto-suffixes` if `forge/`/`forge-rig/` exist in cwd, defeating pre-staging of an extension target repo. Three resolutions, none chosen yet:

1. Run round-2 as a second greenfield of distinct shape (different domain, different language).
2. Bench round-2 manually outside the script (clone twice, invoke each plugin once, diff by hand).
3. Skip round-2 — round-1 + the move-pr-review study suffices for foundation pick.

Decision deferred until round-1 results are in. If round-1 verdict is unambiguous, option 3 is acceptable.

### 11.2 REVIEWERS default

Set to 6 above (one per dimension). Defensible but not validated. The first three real cycles on v2 should record `agreement_count` distributions; if most clusters have agreement = 1 (no overlap between dimensions), 6 is too few. If most have agreement ≥ 4 (every reviewer flagging same things), 6 is too many. Tune to keep median agreement in [2, 3].

### 11.3 Codex cross-check scope

v1 cross-checks at planning gate. v2 could also cross-check the consolidator's `review.md` (does Codex agree with the cluster verdicts?) but this is optional and cost-doubling. Defer until v2 is stable; revisit if reviewer false-positive rate is high.

### 11.4 Single-turn parallel-dispatch detection

The `PreToolUse(Agent)` rule (§8 rule 3) needs a workable heuristic. "Co-issued in the same turn" isn't directly observable to a hook; "second reviewer dispatched after first one completed" is. The hook will use a 5-second window: if `subagent-N.json` exists when the next `reviewer` Agent call fires, that's a serial dispatch. Tune the window after first cycles.

### 11.6 Both variants failed "Evaluation Compliance" cycle-1 — bench-revealed bug

Round-1 surfaced an audit failure both variants share: cycle 1 evaluation verdict comes back as "MISSING" rather than "PASS". This is a forge-protocol bug independent of the foundation choice — neither original nor rig produces a verdict-shaped output the auditor recognizes for cycle 1, even though both clearly advance to cycle 2 successfully.

Two hypotheses, untested:

1. **Auditor parser bug.** The audit script (`forge-audit.mjs`) looks for a specific verdict format (probably `verdict: PASS` or `**PASS**`) in `cycles/<n>/evaluation.md`. Both variants may write the verdict in a slightly different shape that the parser misses. Cycle 2's verdict parses correctly, suggesting the protocol settles into the right format on the second try but not the first.
2. **Real protocol gap.** The cycle 1 evaluator agent never explicitly emits a verdict because the orchestrator dispatches it before the evaluator's prompt was finalized. Cycle 2's orchestrator has more context and writes the verdict more carefully.

Either way: v2 fixes this by *making the verdict a structured artifact*, not free prose. The `consolidated-review` phase's `_consolidated.json` + `cycle-pass.sh` (§9) replaces the prose verdict with a script-checked predicate. There's no "MISSING" possibility — the file is either present and machine-parseable or the cycle doesn't advance.

This is a small but real example of why v2's "gates as code, not prose" principle (§4.5) matters. The bench surfaced it; the v2 design absorbs it for free.

### 11.7 Three-way bench in Phase 5 — acceptance bar

Plan calls for original / rig / v2 head-to-head with same Phase 0 prompts.

**Acceptance bar (resolved):** *v2 must not regress against rig on the forge-audit dimensions; structural wins count even at audit-tie.*

Concretely: v2 ships if all of the following hold:
- Overall audit score ≥ rig's score on the same prompt.
- All v2-specific artifacts (`tests.json`, `red.log`, `green.log`, `_consolidated.json`, `_coverage_matrix.txt`, `review.md`) are present and schema-valid.
- No new audit dimensions regress below rig's score.

This is the pragmatic bar. The audit doesn't reward consolidated multi-dimensional review or TDD-as-phase enforcement — those are real wins the audit can't see. Requiring v2 to *beat* rig on metrics that don't measure its improvements would be the wrong incentive.

If v2 ties on audit AND the new artifacts are clean, ship. Phase 6 (post-ship) can then design audit dimensions that *do* measure the new wins (e.g. "consolidated_review_present", "tdd_red_phase_evidence"), and re-bench under the richer rubric.

---

## 12. Reference table — load-bearing source files

Read these (do not skim) before implementing the corresponding section:

| For section | Read file | Why |
|---|---|---|
| §4.1 (orchestrator) | `~/workspace/dotfiles/.claude/plugins/code-forge/agents/cycle-orchestrator.md` and the other 3 orchestrators | The compression target. |
| §4.2 (TDD as phase) | `~/workspace/agentic-engineering-101/topics/05-tdd.md` | The rationale for hook-enforced anti-patterns. |
| §4.3 (script coordination) | `~/.claude/sui-pilot/skills/move-pr-review/SKILL.md` | Full pattern, including failure modes section. |
| §4.3 (script implementation) | `~/.claude/sui-pilot/skills/move-pr-review/scripts/{validate_schema.sh,consolidate.js,coverage_matrix.sh}` | Direct port targets. |
| §4.4 (coverage backfill) | `~/.claude/sui-pilot/skills/move-pr-review/scripts/coverage_matrix.sh` and SKILL.md "Phase 2" | The leader backfill mechanism. |
| §8 (hooks) | `~/workspace/dotfiles/.claude/plugins/code-forge-rig/hooks/forge-guard.mjs` | Existing rules; new rules extend, don't replace. |
| §10 (migration) | `~/workspace/dotfiles/.claude/plugins/code-forge/agents/*.md` (all 8) | Source prompts to port. |
| Bench acceptance | `~/workspace/dotfiles/.claude/plugins/forge-bench/scripts/forge-audit.mjs` | The 7 audit dimensions v2 must improve on. |

---

## 12.1 v0.2.0 risk additions — protect against

- **Implementer worker collusion.** All N=6 Sonnet workers run from the same model with the same prompt and tests; they may converge on the same wrong-but-test-passing implementation. Counter (v0.2.0): coordinator's pick-best should still pick *the simplest* among passers, which incentivizes lean code over cargo-cult. Counter (deferred to v0.3.x): re-dispatch a portion of workers with mutated prompts (different system message variations) to inject diversity. Diversity signal goes into `synthesis-notes.md` so the issue is observable.
- **E2E remediation loop.** If e2e fails, a remediation cycle is spawned. If the remediation cycle's tests pass but Phase F fails again, you can loop indefinitely. Cap (per §11): 3 remediation cycles. After cap, escalate to user with the e2e gap report.
- **agent-config.md drift.** Once specialist routing bindings are written in Phase 1, they may not match the actual file shape that emerges in cycles 2+. Counter: cycle-init.sh re-reads agent-config.md against the cycle's contract files; if a glob matches a target file but no binding exists, advise the orchestrator to update the config rather than dispatching a generic agent.
- **Phase F skipped silently.** If `spec.md` lacks a `## E2E Tests` section, Phase F is skipped. For a multi-cycle deliverable, that's a strong "you forgot the integration check" signal. forge-guard adds an advisory: cycle-plan with >1 cycle + no e2e tests → warn at Phase 1 exit.
- **Codex-mediated Phase 0 round-trip cost.** claudex flow is expensive (multi-round refinement + Codex calls). For trivial tasks, this is overkill. Counter: a `--quick` flag that skips Phase 0 and goes straight to Phase 1 with the lazy prompt as the plan. Documented in §11.

## 13. Things that have gone wrong before — protect against

(Mirror of move-pr-review's failure-mode section, transposed to forge.)

- **Subagent collusion on same blind spot.** All 6 reviewers run from the same model with the same context; they share blind spots. Counter: leader backfill (R0) on low-coverage files; orchestrator's private smoke-read of the cycle deliverable. Stronger counter (deferred to a future v2.x): fresh CLI session reading the cycle artifacts cold — see §11.0 for the architectural framing.
- **Mega-clustering.** Multiple distinct concerns at the same line range merge into one cluster. The consolidator must split by re-deriving threat paths. Heuristic: if a cluster has ≥3 distinct categories and `agreement_count ≥ 3`, it's a mega-cluster — split.
- **Tautological tests in red phase.** Test "fails" on import error or syntax problem rather than the behavior under test. Counter: forge-guard's red-phase rule requires not just exit code ≠ 0 but a structured failure that mentions the test's behavior. (Phase 5 hook tuning.)
- **Implementer drift toward weakening tests.** Easiest path to green is changing the test, not the code. Counter: test-file edit block during green (§8 rule 1).
- **Serial reviewer dispatch.** Defeats parallelism *and* independence. Counter: §8 rule 3, with the timestamp heuristic.
- **Stale skill-file in agent context.** Agents read SKILL.md once at session start, then drift over long cycles. Counter: scripts implement the gates, not the skill file. The skill file becomes documentation, not protocol.
- **Cycle retry loop.** Same gate fails repeatedly; agent doesn't internalize feedback. Counter: per-phase retry cap = 3, then escalate to user.

---

## 14. Validation plan (Phase 5 in the implementation plan)

1. `cd ~/workspace/dotfiles/.claude/plugins/code-forge-v2 && bash tests/smoke.sh` → 0.
2. `/forge-bench "<round-1 prompt>" --label v2-vs-rig-round-1` against the Phase 0 round-1 prompt → forge-compare verdict ≥ "marginally better" than chosen foundation.
3. End-to-end: run `/forge` on `add a TypeScript helper that …` (small fresh task). Observe in `.forge/`:
   - Phases land in order: `contract → test-list → red → green → consolidated-review`.
   - Forge-guard blocks an attempted test-file edit during green (smoke-tested by deliberate prompt to weaken a test).
   - `consolidated-review` produces 5 reviewer JSONs + a `_consolidated.json` clustered artifact.
4. Codex cross-check on the resulting SKILL.md and a sample cycle's `.forge/` artifact bundle.

Acceptance: all four pass without manual intervention.

---

## 15. Dispatch modes — when a fresh CLI session beats an in-process subagent

The `Task` / Agent tool spawns subagents *in-process*: a constrained reasoning context that shares the parent's process, runs a restricted tool set, cannot pause for user input (no `AskUserQuestion`), cannot appear in a tmux pane (no separate stdin/stdout), and inherits the parent's loaded plugins automatically. It is a thread of reasoning, not a thread of OS activity.

A separate, complementary pattern exists: spawn `claude` as a CLI session inside a tmux pane (the `forge-bench` model). That session has its own context, its own tool set, supports `AskUserQuestion` (because the pane is interactive), is visible to the user in real time, and can be inspected/intervened with mid-flight. The cost is that it does not inherit the parent's transient state — it loads only user-level config — so the parent must hand-stage any artifacts the pane-session needs to read.

These two modes are not interchangeable. They serve different cycle roles. v2 ships day-one with everything in §5 dispatched as in-process subagents. This section enumerates the cycle stages where the **CLI-in-pane** mode would meaningfully improve outcomes, so a later iteration can adopt the pattern selectively.

### 15.1 Candidate stages for fresh-CLI-session dispatch

These are stages where the value being added is **reading existing artifacts and rendering judgment without context contamination from the cycle's reasoning**. The user phrased this concisely: "a fresh Claude session that would be just reading MD files / artifacts that would serve for ruling the forge."

| Stage | Why a fresh CLI session helps | What artifacts the session reads |
|---|---|---|
| Final cycle-pass verdict | Independent of in-cycle reasoning; harder to confirm-bias the verdict because the session has no memory of the planner's, implementer's, or reviewers' arguments. | `cycles/<n>/contract.md`, `tests.json`, `red.log`, `green.log`, `_consolidated.json`, `review.md`. |
| Adversarial review (defense-attorney role) | The session is prompted to *argue against* the cycle's deliverable. Independent context lets it find weaknesses the parent's accumulated assumptions hide. | Same artifact set as final verdict. |
| Codex-equivalent second opinion (Claude flavor) | Adds a Claude-vs-Claude cross-check alongside the existing Claude-vs-Codex one. Same fresh-context property, but stays inside the Anthropic stack. Optional; doubles cost at the gate. | `plan.md`, `cycles/<n>/contract.md`. |
| User-input gates (`AskUserQuestion` mid-cycle) | When a phase needs human judgment ("should we adopt design A or B?"), an in-process subagent cannot ask. A pane session can. | Phase-specific artifacts; the question is rendered to the user, the answer flows back via the pane's stdout. |
| Final-review-across-all-cycles | Replaces the deleted `final-review-orchestrator` with something stronger: a fresh session that reads every cycle's `.forge/` artifacts end-to-end and produces a holistic review. Independent of any single cycle's accumulated reasoning. | The full `.forge/` tree at deliverable completion. |

### 15.2 Why this is deferred from v2 day-one

- **Mode mismatch with current orchestrator design.** §4.1 commits to a thin orchestrator that drives the cycle by invoking scripts. Adding a second dispatch mechanism (CLI-in-pane wrapper) is a generalization, not a complication, but it adds a script (`dispatch-in-pane.sh`) and a way to capture pane output back into the cycle's state. Worth landing as a follow-up after v2 stabilizes.
- **Hook-based interception is harder than it looks.** A `PreToolUse(Agent)` hook that *replaces* every Agent tool call with a CLI-in-pane dispatch is technically feasible but globally affects every multi-agent skill in the install (code-forge, move-pr-review, code-review, …). Many of those assume in-process state inheritance. Per-stage opt-in via explicit script invocation in the orchestrator is safer than a global hook.
- **AskUserQuestion is the load-bearing benefit.** Most stages above don't strictly need a fresh CLI session — they could work as in-process subagents with constrained context. The unique benefit of CLI-in-pane is interactivity. Stages without an `AskUserQuestion` requirement should stay as in-process subagents.

### 15.3 If/when adopted — design sketch

A small `scripts/dispatch-in-pane.sh` wraps the forge-bench tmux split-pane logic. Signature:

```
dispatch-in-pane.sh \
  --label <stage-name> \
  --artifacts <comma-separated paths the session reads> \
  --prompt-file <path to prompt md> \
  --output <path where the session's final answer is captured>
```

The script:
1. Splits the active tmux window into a new pane.
2. Runs `claude` interactively, with the prompt loaded and the artifact paths injected.
3. Waits via `tmux wait-for` for the pane to signal completion.
4. Captures the session's final stdout (or a known output file) and writes it to `--output`.
5. Cleans up the pane.

The orchestrator invokes this script for any of the §15.1 stages it has been configured to delegate. State flows back via the `--output` file, which the orchestrator parses into the cycle's artifact tree.

This pattern is **additive**, not replacing. The default dispatch model stays in-process. CLI-in-pane is opt-in per stage.

### 15.4 Open: when to revisit

After three real cycles complete on v2 day-one, look at:
- Did any cycle's final verdict feel pre-determined by accumulated reasoning? (Smell test for "fresh-session for verdicts.")
- Did any phase need user input that the orchestrator couldn't gracefully request? (Smell test for "AskUserQuestion gates.")
- Did the final-cycle review feel under-rigorous compared to per-cycle reviews? (Smell test for "final-review-across-all-cycles fresh session.")

If any of these tests fail repeatedly, adopt the §15.3 sketch for the failing stage(s).

---

## Glossary (for future-you)

- **Cycle** — one iteration of `contract → test-list → red → green → consolidated-review`. A `/forge` run typically has 1–3 cycles depending on prompt scope.
- **Reviewer** — a `reviewer` agent instance dispatched in parallel during `consolidated-review`. One per dimension.
- **Consolidator** — same agent definition as `reviewer`, but invoked with a different prompt env var. Synthesizes the cluster file into the final `review.md`.
- **R0 / leader** — the orchestrator-as-reviewer that backfills coverage on flagged files.
- **Forge-guard** — `forge-guard.mjs`, the hook that codifies invariants the agents would otherwise drift on.
- **Mega-cluster** — a cluster that contains multiple distinct concerns merged by position-based clustering. Must be split during consolidation.
- **Tautological test** — a test that passes for the wrong reason (e.g., asserts truthy instead of equality). Forge-guard's red-phase rule is designed to catch the most common form.
- **In-process subagent** — an agent spawned via the `Task` / Agent tool. Shares the parent's process and loaded plugins, runs a constrained tool set, returns a single result string. Cannot use `AskUserQuestion`, cannot appear in a tmux pane. The default dispatch model in v2.
- **CLI-in-pane session** — a fresh `claude` interactive session spawned in a tmux pane (the `forge-bench` model). Has its own context and tool set, supports `AskUserQuestion`, is visible to the user in real time. Does *not* inherit the parent's transient state. Reserved for §15.1 stages in a future iteration.
