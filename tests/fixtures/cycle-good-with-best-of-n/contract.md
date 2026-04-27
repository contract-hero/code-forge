# Cycle 1 Contract — strip-ansi helper

## Goal
Add a TypeScript helper that strips ANSI escape codes from a string.

## Behavior
- Exported function `stripAnsi(input: string): string`.
- Returns input unchanged when no ANSI codes are present.
- Removes `\x1b[…m` color/cursor sequences.

## Files
- src/strip-ansi.ts
- src/index.ts

## Acceptance
- `stripAnsi("hello")` → `"hello"`
- `stripAnsi("\x1b[31mred\x1b[0m")` → `"red"`
- `stripAnsi("")` → `""`

## E2E coverage
None for this cycle (unit only).
