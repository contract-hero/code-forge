---
description: "Code Forge v2 — multi-agent planning, TDD-as-phase, and consolidated parallel review with Codex cross-checking. v0.2.0 adds claudex Phase 0, best-of-N implementer, project-domain routing, and e2e Phase F."
argument-hint: "DESCRIPTION [--quick] [--agents ROLES] [--light]"
---

# Code Forge

Initial request: $ARGUMENTS

**Invoke the code-forge skill to begin the orchestration protocol.**

Parse flags from the arguments:
- `--quick` — Skip Phase 0 (claudex). Use the lazy prompt verbatim as `.forge/plan.md`. Trade-off: fewer Codex round-trips for trivial tasks; may produce a less-refined planning prompt. Skip when prompt scope is unclear or the project is unfamiliar.
- `--agents ROLES` — Comma-separated agent role names. Overrides Phase 1's auto-derivation of `agent-config.md`'s `recommended_agents` block. Hard routing (`required_subagents`, `project_domains`) is not affected — those still come from repo-shape detection.
- `--light` — Skip optional Codex gates (G2.5, G5) for cost savings. Keeps G1 (intrinsic to claudex), G2.a (plan↔spec), G2.b (spec↔e2e), and G6.

Strip flags from the description before passing to the skill. The remaining text is the lazy prompt.

## Run shape

```
pre-cycle:  Phase 0 (Plan, claudex)
              → Phase 1 (Spec & e2e + agent-config.md, two Codex loops)
              → Phase 2 (Cycle plan)
per cycle:  contract → test-list → red → green (best-of-N) → consolidated-review
post-cycle: Phase F (e2e-review, if spec.md has ## E2E Tests)
```

If `.forge/state.json` exists in cwd when `/forge` is invoked, the orchestrator resumes from the recorded phase rather than starting fresh.
