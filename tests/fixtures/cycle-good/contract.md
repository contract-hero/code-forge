# Cycle 1 Contract — sloc CLI core

## Behavior

A CLI tool that recursively counts source-lines-of-code under a directory and emits a per-extension breakdown to stdout (text by default, JSON with `--json`).

## Files

- src/sloc.ts — entry point, argv parsing, recursion
- src/format.ts — text vs JSON output formatting
- tests/sloc.test.ts — unit tests for sloc core
- tests/format.test.ts — unit tests for formatter

## Acceptance

- Empty directory returns 0 lines, no warnings
- Mixed extensions produce a per-extension count
- `--json` flag changes output format without changing counts
- Symlinks are followed only when `--follow` is set
