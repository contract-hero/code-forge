---
description: "Code Forge v0.2.0 (Option D) — recursive /goal orchestration. Multi-cycle build with best-of-N workers + configurable dimensional reviewers (count + model + dimensions picked in spec.md). One hook survives (test-file immutability during green)."
argument-hint: "DESCRIPTION [--quick] [--light]"
---

# Code Forge

Initial request: $ARGUMENTS

**Invoke the `code-forge` skill** to launch the outer `/goal` session.
The skill drives Phase 0/1 spec authoring directly (in the outer
session), then spawns one `claude -p /goal` child per cycle.

Parse flags from the arguments:

- `--quick` — Skip Phase 0 (claudex). Use the description verbatim as
  `.forge/plan.md`. Trade-off: fewer Codex round-trips for trivial
  tasks; may produce a less-refined planning prompt.
- `--light` — Skip the optional Codex G2.5 gate. Keeps G1 (intrinsic
  to claudex), G2.a (plan↔spec), G2.b (spec↔e2e).

Strip flags from the description before passing to the skill. The
remaining text is the lazy prompt.

## Run shape

```
pre-cycle:  Phase 0 (Plan, claudex)
              → Phase 1 (Spec + E2E + Cycle Plan + Reviewer Config)
per cycle:  one claude -p /goal child per cycle plan entry
              → test-author → red → 6 best-of-N workers → score → pick
              → N reviewers (count + model + dimensions from spec.md)
              → consolidator → result.json
```

If `.forge/state.json` exists in cwd when `/forge` is invoked, the
outer session resumes from the recorded `current_cycle`.

## See also

- `docs/goal-integration.md` — the outer + cycle-child procedure.
- `templates/spec.md.template` — the 10-block spec skeleton.
- `skills/code-forge/SKILL.md` — the high-level map.
