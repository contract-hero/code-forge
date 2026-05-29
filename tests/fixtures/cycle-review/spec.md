# Cycle-review fixture spec

## Vision
A tiny fixture exercising the review-stage Workflow's inputs.

## Acceptance Criteria
- AC-001 — example function behaves per tests.

## Architecture
Single module `src/example.ts`.

## Out of Scope
- Anything not under src/example.ts.

## E2E Tests
- E-001 — n/a for this fixture.

## Cycle Plan
- id: CX
  goal: implement example
  files_affected:
    - src/example.ts
  acceptance: [AC-001]

## Reviewer Config
```yaml
model: opus
dimensions:
  - correctness
  - simplicity
  - security
```
