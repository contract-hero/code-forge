# Agent routing decisions

Where the v0.2.0 design lands on **which subagent_type to dispatch** for a given role + project context. Three layers of decision, each with its own enforcement strength.

## The three blocks of `agent-config.md`

Phase 1 (Spec & e2e) emits `.forge/agent-config.md` with three top-level YAML blocks. They serve different purposes and have different enforcement.

```yaml
---
project_domains:                      # v0.2.0: top-level project-wide tags.
  - sui-dapp                          # When sui-dapp is present: every Task call
                                      # in the run uses sui-pilot:sui-pilot-agent
                                      # regardless of file. Role behavior is
                                      # delivered via prompt injection.

required_subagents:                   # Hard glob-based routing. Correctness-grade
  - match: "**/*.move"                # specialists only. Fallback when no
    subagent_type: "sui-pilot:sui-pilot-agent"
    applies_to: [planner, implementer-worker, reviewer]
                                      # project_domain is set.
  - match: "Move.toml"
    subagent_type: "sui-pilot:sui-pilot-agent"
    applies_to: [planner, implementer-worker]

recommended_agents:                   # Soft roster. Curated from user's enabled
  - subagent_type: "sui-pilot:sui-pilot-agent"
    rationale: "Primary Sui specialist; user-favored."
    suitable_for: [planner, test-author, implementer, reviewer]
    domain_relevance: high
  - subagent_type: "impeccable:impeccable-agent"
    rationale: "Frontend specialist; user-favored for UI work."
    suitable_for: [implementer-worker, reviewer]
    domain_relevance: medium
  - subagent_type: "superpowers:test-driven-development"
    rationale: "Cross-cutting TDD discipline."
    suitable_for: [test-author, implementer]
    domain_relevance: high
---
```

## Decision hierarchy

When the orchestrator dispatches a Task call:

1. **`project_domains`** (highest priority — hard rule). If the project is tagged `sui-dapp`, dispatch sui-pilot regardless of file or role. Role behavior is injected into the prompt.
2. **`required_subagents`** (hard glob rule). If a file matches a glob, the binding's `subagent_type` is required. Fallback for projects without a domain tag, or for projects that didn't tag the whole domain but have specific file types that demand specialist review.
3. **`recommended_agents`** (soft preference). Among agents the orchestrator could dispatch, prefer roster members whose `suitable_for` includes the role and whose `domain_relevance` is `high`, then `medium`, then general-purpose.

Hard rules win over soft preferences. The two hard layers (project_domain, required_subagents) cooperate: project_domain subsumes the per-glob rules for the dimension it covers, but the per-glob rules still apply for specialist concerns inside non-tagged projects.

## Hard vs soft enforcement principle (decided 2026-04-26)

**Only correctness-grade specialists are hard-required.** Quality-preference specialists live in `recommended_agents`.

- **sui-pilot for Move files** → hard. The Sui ecosystem evolves fast enough that LLM training data goes stale; non-sui-pilot Move review has a high false-confidence risk. That's a correctness concern.
- **impeccable for frontend** → soft. General-purpose agents write competent React; impeccable just makes it nicer. Quality preference, not correctness. Forcing it on every `*.tsx` would over-constrain the orchestrator.
- **superpowers/* (TDD, verification-before-completion)** → soft. Cross-cutting discipline that helps but doesn't gate correctness.

When adding a new "user-favored" plugin, default to soft-recommend. Promote to hard-require only when missing the specialist creates a real correctness gap, not just a quality gap.

## Project-domain compound routing — the pattern

When `project_domains` contains `sui-dapp`, **every Task dispatch in the entire run** uses `subagent_type=sui-pilot:sui-pilot-agent`. This includes TS/JS/frontend/CLI files, not just `.move` content. Reasoning:

- A TypeScript file in a Sui dApp project is still Sui-context work. The agent touching it should know about dapp-kit, wallet adapters, on-chain RPC patterns.
- File-glob rules don't catch the SDK code in `src/sui-client.ts` (no `*.move` extension), but that code is also Sui-context and needs sui-pilot's live-doc awareness.
- A project-domain marker is the right granularity for "this whole run is Sui work."

**How role behavior survives:** the role-specific instructions in `agents/test-author.md`, `agents/implementer.md`, `agents/reviewer.md`, etc. become *role-prompt templates* the orchestrator embeds in the Task call's `prompt` parameter. The dispatched agent is sui-pilot; what it does this turn is shaped by the embedded role prompt.

```python
# Conceptually, every dispatch when project_domains contains sui-dapp:
Task(
  subagent_type="sui-pilot:sui-pilot-agent",
  prompt=f"""
    {render_role_prompt('test-author', cycle=2)}

    [+ usual cycle context: contract.md, tests.json, etc.]
  """
)
```

This satisfies "every agent should be sui-pilot, on top of any other agent it should be" — composition via prompt, not via dual-dispatch (which Claude Code's `Task` tool doesn't support natively).

## Recommended-agents and project-domain together

When project_domain forces a fixed `subagent_type`, the `recommended_agents` block doesn't disappear — it shifts role from **dispatch routing** to **prompt composition**. Example: if the recommended roster includes `impeccable:impeccable-agent` for frontend work and the project is tagged `sui-dapp`, the orchestrator's prompt to sui-pilot for a `.tsx` file becomes "act as sui-pilot but apply impeccable's frontend design discipline."

The roster's entries become prompt-fragment hints rather than dispatch decisions. Same favoritism, different mechanism.

## User-level preference (alilloig's local install)

For alilloig's primary forge usage, `recommended_agents` should preferentially surface:

- **sui-pilot** (anything Sui/Move/Walrus/Seal-related)
- **impeccable** (anything frontend/UI-related)
- **superpowers/\*** (cross-cutting workflow discipline)

These are the plugins he has invested in and trusts most. The planner enumerates `enabledPlugins` from `~/.claude/settings.json` during Phase 1 and surfaces these favored plugins first in the roster.

## forge-guard rule 6

The blocking enforcement for the routing layer above lives in `hooks/forge-guard.mjs` rule 6:

```
PreToolUse(Task) hook:
  read agent-config.md (project_domains + required_subagents)

  if "sui-dapp" in project_domains:
    if tool_input.subagent_type != "sui-pilot:sui-pilot-agent":
      reject with reason "project_domain=sui-dapp forces sui-pilot"

  for each binding in required_subagents:
    if work_scope_matches_binding(binding):
      if tool_input.subagent_type != binding.subagent_type:
        reject with reason "binding requires X for Y files"
```

Skipped when no `agent-config.md` exists (greenfield, no specialist needed).

## See also

- `spec.md` §4.7, §4.7.1, §4.7.2, §7.5 — the canonical design.
- `docs/implementation-summary.md` — what's actually built (v0.1.0) vs designed (v0.2.0).
