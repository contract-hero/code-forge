# code-forge

A Claude Code plugin that turns a lazy prompt into a shippable PoC/MVP through
recursive `/goal` orchestration, TDD-as-phase, best-of-N implementer workers,
and configurable dimensional review.

> **Visual walkthrough — [alilloig.github.io/code-forge](https://alilloig.github.io/code-forge/)**
> The GitHub Pages landing is the easiest way to understand what Code Forge
> does: cycle architecture diagrams, the dimension menu, the surviving hook,
> and a quick-start. Source: [`docs/index.html`](./docs/index.html).

## Install

Two paths, both Claude-Code-native:

| Path | What it gives you |
|---|---|
| **Submodule at `~/.claude/code-forge/`** (recommended) | Single source-of-truth; `git submodule update --remote --merge code-forge` to update |
| **Marketplace install** (`/plugin install contract-hero/code-forge@main`) | Drop-in via Claude Code's plugin marketplace |

Requirements:

- **Claude Code v2.1.139+** — `/goal` is load-bearing.
- **`codex-bridge` plugin** — the planner uses Codex via MCP for the
  spec ↔ plan and spec ↔ e2e cross-checks.
- **Hooks enabled** (`disableAllHooks: false` in settings). The one
  anti-cheat invariant is a `PreToolUse` hook; disabling it lets
  `/goal "tests pass"` rewrite the tests.
- **`jq` + `node`** in `PATH` for the validator and the hook.

## Quick start

```text
/forge "Build a CLI that counts source lines"
```

Flags:

- `--quick` — skip Phase 0 (claudex). Use the description verbatim as
  `.forge/plan.md`. Trade-off: fewer Codex round-trips for trivial tasks;
  may produce a less-refined planning prompt.
- `--light` — skip the optional Codex G2.5 gate. Keeps G2.a (plan↔spec)
  and G2.b (spec↔e2e).
- `--resume` — allow reuse of an existing `.forge/` directory.

```text
/forge "Add a --json flag to my CLI" --quick
/forge "<description>" --light
/forge "<description>" --resume
```

That's the only entry point. The `code-forge` skill drives the run in your
interactive session — Phase 0 → Phase 1 → cycle loop — spawning one
`claude -p /goal` child per cycle for the autonomous bits.

## How it works

```
/forge "task"
    │
    ▼ (skill drives in your session)
Phase 0 (claudex) → Phase 1 (planner authors spec.md)
    │
    ▼ (skill loops over cycles)
spawn:  claude -p /goal "<per-cycle condition>"
    │
    ▼ (cycle child: test-author → red → 6 workers → score → reviewers → consolidator)
    result.json  ← skill reads, narrates "cycle X status=pass", continues
```

`/goal` is one-goal-per-session by design. The cycle child uses session
boundaries to give each cycle its own `/goal` + Haiku evaluator while the
skill keeps managing the outer loop.

Inside a cycle:

1. **test-author** writes `tests.json` + the actual test files for the
   cycle's acceptance criteria.
2. **red gate**: `cycle-tests-pass.sh red` proves the tests fail correctly
   (inverted exit code catches tautological tests).
3. **6 implementer-workers** dispatch in parallel, each writing an
   independent candidate under `cycles/<id>/green/candidates/worker-K/`.
4. **Score and pick** the simplest passer (LOC → files → complexity
   proxy); apply via rsync.
5. **N reviewers** dispatch in parallel. Count, model (`opus` or `sonnet`),
   and per-reviewer dimension all come from `spec.md ## Reviewer Config`.
6. **consolidator** clusters findings by file+line proximity, verifies
   critical/high against source, writes `review.md` with a machine-readable
   `Cluster summary` block.
7. **result.json** is written with `status: pass | fail` + `review_clusters`.
   The cycle child's `/goal` clears once status is pass and critical=0.

Sequential cycles run until every cycle's status is pass, or the skill
halts on a failure (so you can investigate `review.md` and re-invoke
`/forge` with `--resume`).

## Configuring the reviewer fan-out

Each cycle's reviewers come from `spec.md ## Reviewer Config`:

```yaml
## Reviewer Config
model: opus            # or sonnet
dimensions:
  - correctness        # ★ default trio
  - simplicity         # ★ default trio
  - security           # ★ default trio
```

The **length of `dimensions`** is the reviewer count — no separate
`count:` field. Want two security reviewers? List `security` twice.

Curated menu (planner Phase 1.5 multi-select):

- **Tier 1** — `correctness`, `design`, `error-handling`, `simplicity`,
  `tests-vs-impl`, `security`
- **Tier 2** — `performance`, `naming-readability`, `dependency-hygiene`,
  `type-safety`, `concurrency`, `observability`
- **Tier 3** (declare per-project, not shown by default) —
  `sui-move-idioms`, `frontend-a11y`, `api-contract-stability`

See `agents/reviewer.md` for the dimension-to-lens map.

## The one hook

`hooks/forge-guard.mjs` blocks Edit/Write/Bash writes that would weaken
the test suite during green phase. Without it, `/goal "tests pass"` would
mutate tests instead of the implementation — the evaluator can only see
what ends up in the transcript and cannot diff against a baseline.

Coverage:

- Edits/Writes to any path listed in `tests.json[*].test_file`.
- Edits/Writes to `.forge/state.json` and `.forge/cycles/<id>/tests.json`
  themselves (the anchors the rule reads from).
- Bash file-writes via `>`, `>>`, `&>`, `>|`, `2>`, `| tee`, `cp`, `mv`,
  `install`, `cp -t <dir>`, GNU + BSD `sed -i`, `perl -i`, `ruby -i`,
  `awk -i inplace`, `python -c open(...,"w")`, `dd of=`, `truncate`,
  `ln -sf`, `rm`, and `sh -c` / `bash -c` / `eval` / here-string
  invocations referencing any of the above.

The hook is fail-closed: any unexpected error exits 2 with a diagnostic
rather than letting the tool call through.

## Repo layout

```
.
├── README.md
├── .claude-plugin/plugin.json
├── commands/
│   ├── forge.md            # /forge entry — invokes the code-forge skill
│   └── forge-smoke.md      # /forge-smoke — runs tests/smoke.sh
├── agents/
│   ├── planner.md          # Phase 1 spec author (incl. Reviewer Config sub-step)
│   ├── test-author.md
│   ├── implementer-worker.md
│   ├── reviewer.md         # generic dimensional reviewer
│   └── consolidator.md     # inline clustering + verification + review.md
├── hooks/
│   ├── hooks.json
│   └── forge-guard.mjs     # one rule — test immutability during green
├── scripts/
│   ├── cycle-init.sh       # scaffold a cycle dir
│   ├── cycle-validate.sh   # schema validator
│   ├── cycle-tests-pass.sh # red/green truth gate (inverts at red)
│   └── forge-status.sh     # dashboard
├── skills/code-forge/SKILL.md
├── templates/spec.md.template
├── docs/
│   ├── index.html          # GitHub Pages landing
│   └── goal-integration.md # full protocol (skill + cycle child)
└── tests/
    ├── smoke.sh            # plugin self-test
    └── fixtures/
```

## Self-test

```text
/forge-smoke
```

Runs `tests/smoke.sh` against the fixtures. Exits 0 iff every assertion
passes.

## Related

- [`sui-pilot`](https://github.com/contract-hero/sui-pilot) — source of the
  parallel-review pattern (`move-pr-review` skill).
- [`codex-bridge`](https://github.com/contract-hero/codex-bridge) — Codex MCP
  integration used by the planner's spec/e2e cross-checks.
