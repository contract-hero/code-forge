# Counter dApp — Specification (bullets-shape negative fixture)

## Vision

Bare-bones spec used to verify that `e2e-extract.sh` rejects (or produces a
non-validating output for) free-form markdown bullets in the `## E2E Tests`
section. The planner is told to emit fenced YAML; this fixture is what it
must NOT emit.

## Core Features

- F1 — A thing.

## Architecture Overview

None.

## E2E Tests

- **E-001 — User signs in.** User opens `/sign-in`, enters credentials, and lands on the dashboard. Expected: dashboard renders the current counter.
- **E-002 — CLI help prints usage.** Run `myapp --help`. Expected: stdout contains `Usage:`.
- **E-003 — Leaderboard.** After incrementing, user appears in the leaderboard. Expected: top-1 is the current user.
