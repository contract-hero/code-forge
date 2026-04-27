---
description: "Run code-forge-v2's self-test against fixtures. Validates that all orchestration scripts behave correctly on known-good and known-bad inputs."
argument-hint: "(no arguments)"
---

# Forge Smoke

Run `tests/smoke.sh` — the v2 plugin's self-test. Use this before pushing changes; CI runs the same script at the merge boundary.

## Instructions

Run the smoke test:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/tests/smoke.sh"
```

Report:
- Exit 0 → all assertions passed; the plugin is safe to use.
- Exit non-zero → some assertion failed; the plugin scripts have a bug. Read the script's stderr; fix; re-run.

The smoke test asserts:

1. `cycle-validate.sh` accepts the `cycle-good` fixture and rejects the bad fixtures.
2. `cycle-consolidate.mjs` produces the expected cluster count and severity distribution from the good fixture.
3. `cycle-coverage.sh` flags the expected files in the good fixture's coverage matrix.
4. `cycle-pass.sh` returns 0 on `cycle-good` and non-zero on `cycle-bad-disputed`.
5. `cycle-tests-pass.sh red` correctly inverts exit codes (passing tests at red = phase fails).
6. `jq` and `node` are present.

If any assertion fails, the plugin should not be used until fixed. Report the failure to the user with the exact assertion that broke.
