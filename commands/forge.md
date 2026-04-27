---
description: "Code Forge v2 — multi-agent planning, TDD-as-phase, and consolidated parallel review with Codex cross-checking. Forked from code-forge-rig with extended forge-guard hooks."
argument-hint: "DESCRIPTION [--agents ROLES] [--light]"
---

# Code Forge

Initial request: $ARGUMENTS

**Invoke the code-forge skill to begin the orchestration protocol.**

Parse flags from the arguments:
- `--agents ROLES` — Comma-separated agent role names from AGENTS.md (e.g., `--agents move-agent,frontend-agent`). Overrides auto-detection.
- `--light` — Skip optional Codex gates (G1c, G3, G4) for cost savings. Keeps G1a, G1b, G2, G5, G6.

Strip flags from the description before passing to the skill. The remaining text is the lazy prompt.
