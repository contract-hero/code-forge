# Code Forge Rig — Enforcement-Hardened Multi-Agent Build System

Code Forge enhanced with programmatic enforcement hooks inspired by [claude-rig](https://github.com/franklywatson/claude-rig). Same multi-agent protocol as [code-forge](../code-forge/), but with hook-based guardrails that prevent the orchestrator from drifting off-protocol during long sessions.

## Why This Variant Exists

Code Forge's orchestrator follows a ~500-line SKILL.md protocol. In end-to-end testing, the primary failure mode was **protocol drift** — as sessions grew long, the orchestrator would skip phases, bypass Codex gates, or advance past failed evaluations. These are exactly the problems that prose-only instructions cannot reliably prevent.

Code Forge Rig adds a `forge-guard.mjs` hook that enforces the protocol's critical invariants as code. Hooks run as separate processes — the orchestrator cannot talk its way around them.

## What's Different From code-forge

Everything in code-forge is preserved. The only addition is `hooks/`:

```
code-forge-rig/
  hooks/
    hooks.json          # Hook registration (PreToolUse + PostToolUse)
    forge-guard.mjs     # Enforcement script (348 lines)
  agents/               # Same as code-forge
  commands/             # Same as code-forge
  skills/               # Same as code-forge
  .claude-plugin/       # Updated plugin.json with new name
```

## Enforced Invariants

### Blocking (PreToolUse — exit 2)

| Invariant | Trigger | What It Prevents |
|-----------|---------|-----------------|
| Contract before implementation | Write to `cycles/N/implementation-notes.md` | Starting implementation without a negotiated completion contract |
| Evaluation before advance | Write to `cycles/N+1/contract.md` | Moving to the next cycle when the current one has FAIL or no evaluation |

### Advisory (PostToolUse — stderr warning)

| Invariant | Trigger | What It Catches |
|-----------|---------|----------------|
| Phase ordering | Write to `status.md` | Jumping to a phase when prerequisite artifacts are missing |
| Codex gate compliance | Write to `status.md` | Missing Codex review artifacts at required gates (respects `--light` mode) |

## How the Hooks Work

The `forge-guard.mjs` script intercepts all `Write` and `Edit` tool calls targeting `.forge/` paths:

1. **Reads the tool input** from stdin (JSON with `tool_name` and `tool_input.file_path`)
2. **Skips non-forge files** — zero overhead for normal editing
3. **Runs invariant checks** against the current `.forge/` artifact state
4. **Blocks or advises** based on the check type

The hook derives state by:
- Parsing YAML frontmatter from `.forge/status.md` and `evaluation.md` files
- Checking file existence for prerequisite artifacts
- Extracting cycle numbers from file paths

No external dependencies. No network calls. Runs in <100ms.

## Quick Start

Same as code-forge — just use this plugin instead:

```
/forge "Build a real-time task management app with WebSocket collaboration"
```

The hooks are transparent. You'll only notice them when they prevent a protocol violation — a `[BLOCK]` message when the orchestrator tries to skip a required step, or an `[ADVISE]` warning when prerequisite artifacts are missing.

## Example: Hook in Action

If the orchestrator tries to write implementation notes before creating a contract:

```
[BLOCK] Forge Guard: missing contract

Cannot write implementation notes for cycle 2 — no contract found.
Expected: /path/to/.forge/cycles/2/contract.md

The forge protocol requires a negotiated completion contract (Phase 5a)
before implementation begins. Complete contract negotiation first.
```

The tool call is rejected (exit 2). The orchestrator must create the contract first.

## Benchmarking

Use the [forge-bench](../forge-bench/) companion plugin to run head-to-head comparisons between code-forge and code-forge-rig:

```
/forge-bench "Build a CLI tool in Rust" --budget 60
```

Or audit any existing forge run:

```
/forge-audit path/to/.forge
```

## Design Rationale

The enforcement approach comes from studying [claude-rig](https://github.com/franklywatson/claude-rig), a TypeScript middleware harness for Claude Code. Key patterns adopted:

- **Composable check functions** — each invariant is an independent function returning `string | null`, combined with `violations.join('\n\n---\n\n')`
- **`[BLOCK]`/`[ADVISE]` prefix convention** — consistent message format matching rig's enforcement pipeline
- **Graceful degradation** — unparseable input or missing files result in exit 0 (never crash the hook)
- **Artifact-based validation** — check file existence and frontmatter instead of tracking runtime state

## Plugin Dependencies

Same as code-forge:

| Plugin | Status | Purpose |
|--------|--------|---------|
| `codex-bridge@local` | **Required** | Provides Codex MCP tools for all gates |
| `superpowers@claude-plugins-official` | **Strongly Recommended** | Behavioral meta-skills reinforce protocol rigor |

## See Also

- [code-forge](../code-forge/) — Original variant (prose-only protocol, no hooks)
- [forge-bench](../forge-bench/) — A/B benchmarking framework
- [claude-rig](https://github.com/franklywatson/claude-rig) — The enforcement patterns this variant is based on
