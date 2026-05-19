---
description: "Run code-forge's self-test against fixtures. Validates that all orchestration scripts behave correctly on known-good and known-bad inputs."
argument-hint: "(no arguments)"
---

# Forge Smoke

Run `tests/smoke.sh` — the plugin's self-test. Use before pushing changes.

## Instructions

Run the smoke test:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/tests/smoke.sh"
```

Report:
- Exit 0 → all assertions passed; the plugin is safe to use.
- Exit non-zero → some assertion failed; read the script's stderr,
  fix, re-run.

The smoke test asserts (Option D set):

1. `cycle-validate.sh` accepts the `cycle-good` fixture and rejects
   the `cycle-bad-tests-schema` fixture.
2. `cycle-tests-pass.sh red` correctly inverts exit codes (passing
   tests at red = phase fails).
3. `cycle-init.sh` scaffolds the cycle directory (`tests.json`,
   `reviewers/`, `green/candidates/`).
4. `forge-guard.mjs` blocks Edit/Write/Bash to test-file paths during
   green phase (rule 5 — the surviving anti-weakening rule).
5. `forge-guard.mjs` peels candidate-staging prefixes so workers can't
   weaken tests via their own candidate directory.
6. `forge-status.sh` runs and emits its header.
7. `jq` and `node` are present.

If any assertion fails, the plugin should not be used until fixed.
Report the failure with the exact assertion that broke.
