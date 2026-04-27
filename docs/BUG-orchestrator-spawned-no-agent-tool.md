# Bug: forge-orchestrator halts immediately when dispatched as a subagent

**Filed:** 2026-04-27
**Filed by:** main Claude Code session driving SEDEFI-176 (deepbook-sandbox-evaluation-apps worktree)
**For:** `code-forge-v0.2.0-implementation` session (this worktree, branch `worktree-forge-fix-v0.3`)
**Severity:** Blocking. `/forge` is unrunnable end-to-end as currently wired.
**Reproduces in:** `code-forge-v2` v0.2.0 (deployed copy at `~/workspace/dotfiles/.claude/plugins/code-forge-v2/`).

## TL;DR

The skill instructs the main session to "Dispatch the **forge-orchestrator** agent." The orchestrator's own preamble immediately halts when it detects it has no `Agent`/`Task` tool. Spawned subagents in Claude Code do **not** inherit the `Agent` tool (only the parent session has it), so the orchestrator can never satisfy its own preconditions. The skill's hand-off step is fundamentally incompatible with the agent's halt-rule.

## What I observed

1. User invoked `/code-forge-v2:forge <SEDEFI-176 brief>` from the main session.
2. The skill (`skills/code-forge/SKILL.md`) loaded. I parsed flags (none), wrote `.forge/state.json` (`phase: "plan"`), wrote `.forge/lazy-prompt.md`.
3. Per SKILL.md §"Hand-off to forge-orchestrator", I dispatched `code-forge-v2:forge-orchestrator` via the Agent tool.
4. The spawned orchestrator immediately halted, citing its own §"Critical: where you run":
   > *"If invoked from a context without `Task`, halt and tell the user: 'forge-orchestrator requires the Task tool — run /forge from the top-level session.'"*
5. The orchestrator confirmed it had only `Read, Bash, Edit, Write, mcp__codex__codex, mcp__codex__codex-reply` available — no `Agent`/`Task`.
6. Net effect: `.forge/plan.md` was never produced. One Codex G0 call (thread `019dcfbe-c192-72c3-ae8a-122a9a1f0079`) was consumed, then orphaned.

## Why this happens

Claude Code subagent semantics: when an agent is spawned via the `Agent` tool, its tool surface is the intersection of (its declared `tools:` frontmatter) and (the parent's available tools, minus parent-only tools like `Agent`). The `Agent`/`Task` capability is **not** inheritable across the spawn boundary — only the top-level session can dispatch subagents. This is by design — it prevents arbitrary subagent recursion.

The orchestrator's frontmatter declares:
```yaml
tools: Glob, Grep, LS, Read, Bash, Edit, Write, Agent, AskUserQuestion, mcp__codex__codex, mcp__codex__codex-reply
```

The `Agent` entry is **declarative wishful thinking** — the runtime strips it on spawn. The orchestrator notices the strip and self-aborts (correctly, given its own design intent).

## Where the contradiction lives

Two places say opposite things:

**1. `skills/code-forge/SKILL.md` §"Hand-off to forge-orchestrator"** (lines 149-157):
> "After parsing flags from `$ARGUMENTS` and creating `.forge/state.json` for a fresh run:
> 1. Initialize `.forge/state.json` with the parsed flags and `phase: "plan"` ...
> 2. **Dispatch the forge-orchestrator agent** with the lazy prompt and the path to `.forge/`.
> 3. The forge-orchestrator runs Phase 0 → Phase 1 → Phase 2, then loops cycles, then runs Phase F (if applicable).
> 4. When `.forge/state.json` reports `phase: "done"`, surface the final review path to the user."

**2. `agents/forge-orchestrator.md` §"Critical: where you run"** (lines 11-13):
> "**You MUST run from the main Claude Code session.** Do NOT run from inside another spawned subagent. Spawned subagents lack the `Task` tool, which means they cannot dispatch the parallel reviewers and best-of-N workers this orchestrator depends on. **If invoked from a context without `Task`, halt** and tell the user: 'forge-orchestrator requires the Task tool — run /forge from the top-level session.'"

The agent's halt-rule is correct (the protocol genuinely cannot work without `Agent`). The skill's hand-off step is wrong — it dispatches into a context that violates the agent's preconditions every time.

## What the fix should do

Two viable shapes (pick one — they're not compatible):

### Option A — main session IS the orchestrator (skill-as-procedure)

Treat `agents/forge-orchestrator.md` as a **procedure manual loaded into the main session**, not a dispatchable subagent. SKILL.md's hand-off step rewrites to:

> "After parsing flags and creating `.forge/state.json`:
> 1. Read `agents/forge-orchestrator.md` — that's your procedure manual.
> 2. Drive Phase 0 → Phase 1 → Phase 2 → cycles → Phase F yourself, dispatching planner / test-author / implementer / reviewer / consolidator / codebase-explorer subagents as the manual instructs.
> 3. Update `.forge/state.json` before every phase transition."

And remove `code-forge-v2:forge-orchestrator` from the dispatchable agent registry, OR keep it as a no-op stub whose only job is to print the halt message (so anyone who tries to dispatch it gets a clear redirect).

Pros: matches the design intent ("the orchestrator runs in the main session"). Doesn't fight the runtime.
Cons: blows the main session's context window over a many-hour run. The whole point of orchestrator-as-subagent was to keep the cycle bookkeeping out of the main context.

### Option B — keep orchestrator as subagent, but inject Agent dispatch via a script proxy

Have the orchestrator subagent write its dispatch intents to a file (e.g., `.forge/dispatch-queue.json`) and have the main session poll/drain that queue, performing the actual `Agent` calls and writing back results. The orchestrator never holds `Agent` itself — it just *requests* dispatches.

Pros: preserves context isolation. Orchestrator stays in subagent.
Cons: significant new infrastructure (dispatch queue + main-session polling loop). Heavy for a fix.

### Option C (interim) — document that the user must run `/forge` then immediately instruct Claude to take over orchestration

Lowest-cost: keep both files as-is, but add a §"Known limitation" to README.md saying `/forge` currently requires the user to acknowledge the halt and then say "OK, drive it from here." Nobody likes interim docs as fixes, but this unblocks today.

## Where I went from here in the SEDEFI-176 run

I (the main session) am proceeding with **Option A inline** — using `agents/forge-orchestrator.md` as my procedure manual and driving the run from this session. State preserved:

- `/Users/alilloig/workspace/deepbook-sandbox-evaluation-apps/.claude/worktrees/alilloig+SEDEFI-176/.forge/state.json` (still `phase: "plan"`)
- `/Users/alilloig/workspace/deepbook-sandbox-evaluation-apps/.claude/worktrees/alilloig+SEDEFI-176/.forge/lazy-prompt.md`

The Codex G0 thread from the halted spawn (`019dcfbe-c192-72c3-ae8a-122a9a1f0079`) is orphaned — restarting from G0 per the claudex skill's "Thread lost mid-protocol" rule.

## Other things I noticed while debugging this

These aren't bugs in v0.2.0, just observations:

- The SKILL.md "Critical: where this skill must run" warning at the top (lines 36-42) talks about the *skill* needing to run from the main session. That part is correct and was satisfied — the user did invoke `/forge` from the top-level session. The skill loaded fine. The break is downstream, at the hand-off step.
- The orchestrator's halt message tells the user to "run /forge from the top-level session" — but that's exactly what the user did. The message blames the wrong layer; in practice the user has done nothing wrong.
- `forge-guard` rule 7 (`checkWorkerFanout`) and rule 3 (`checkParallelReviewerFanout`) both depend on the orchestrator owning the dispatch site. If we go with Option A, the main session is the dispatch site and the rules still work. If we go with Option B, the rules need to look at the proxy-queue, not at `Task` tool calls.

## Suggested next step for the v0.2.0 implementation session

Pick Option A or Option B and land it before the next CI run of `/forge-smoke`. The smoke test doesn't catch this (it tests the scripts, not the dispatch chain), so it's been silently broken since the orchestrator's halt-rule was added.

— main session driving SEDEFI-176, 2026-04-27 16:17 UTC
