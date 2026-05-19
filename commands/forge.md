---
description: "Code Forge — multi-agent build system driven by recursive /goal orchestration. Authors a spec, then runs sequential cycles with best-of-N workers + configurable dimensional reviewers. One hook keeps test files read-only during green."
argument-hint: "DESCRIPTION [--quick] [--light] [--resume]"
---

# Code Forge

Initial request: $ARGUMENTS

**Invoke the `code-forge` skill** to start the run. The skill drives the
whole protocol in this interactive session: Phase 0 (claudex) → Phase 1
(planner authors `spec.md`) → cycle loop (one `claude -p /goal` per
cycle).

Flags:

- `--quick` — Skip Phase 0 (claudex). Use the description verbatim as
  `.forge/plan.md`. Trade-off: fewer Codex round-trips for trivial
  tasks; may produce a less-refined planning prompt.
- `--light` — Skip the optional Codex G2.5 gate. Keeps G2.a (plan↔spec)
  and G2.b (spec↔e2e).
- `--resume` — Allow reuse of an existing `.forge/` directory. Without
  this flag, a non-empty `.forge/state.json` triggers a prompt before
  the skill continues.

## See also

- `docs/goal-integration.md` — the full protocol (skill + cycle child).
- `templates/spec.md.template` — the 10-block spec skeleton.
- `skills/code-forge/SKILL.md` — the orchestration logic this command
  loads.
