# code-forge

A multi-agent build system that turns lazy prompts into shippable PoCs/MVPs
through recursive `/goal` orchestration, TDD-as-phase, best-of-N implementer
workers, and configurable dimensional review.

> **Visual walkthrough — [alilloig.github.io/code-forge](https://alilloig.github.io/code-forge/)**
> The GitHub Pages landing is the easiest way to understand what Code Forge
> does: outer + per-cycle architecture diagrams, the dimension menu, the
> surviving hook, and a quick-start. Source: [`docs/index.html`](./docs/index.html).

## Install

Code Forge ships as a Claude Code plugin. Two common install paths:

| Path | What it gives you |
|---|---|
| Submodule at `~/.claude/code-forge/` (recommended) | Single source-of-truth; pull the submodule to update |
| Marketplace install (`/plugin install alilloig/code-forge@main`) | Drop-in via Claude Code's plugin marketplace |
| Local checkout + `bash scripts/deploy.sh` | Legacy install at `~/.claude/plugins/code-forge/`; rsyncs the plugin tree |

Requirements:

- **Claude Code v2.1.139+** — `/goal` is load-bearing.
- **`codex-bridge` plugin** — the planner uses Codex via MCP for the spec ↔ plan
  and spec ↔ e2e cross-checks.
- **Hooks enabled** (`disableAllHooks: false` in settings). The one anti-cheat
  invariant is a `PreToolUse` hook; disabling it lets `/goal "tests pass"`
  rewrite the tests.
- **`jq` + `node`** in `PATH` for the validator and the hook.

## Quick start

```bash
# From inside Claude Code:
/forge "Build a CLI that counts source lines"

# From a terminal:
bash scripts/forge.sh "Build a CLI that counts source lines"

# Skip Phase 0 (Codex-mediated planning refinement) for trivial tasks:
bash scripts/forge.sh "Add a --json flag to my CLI" --quick

# Skip the optional G2.5 Codex gate (cost savings):
bash scripts/forge.sh "<description>" --light

# Resume a run that left a partial .forge/ behind:
bash scripts/forge.sh "<description>" --resume
```

The launcher spawns the outer Claude session with this `/goal` active:

> *every cycle id in `.forge/spec.md ## Cycle Plan` has produced a corresponding
> `cycles/<id>/result.json` file containing `status: pass`, or stop after K
> outer turns*

That outer session reads the spec, picks the next pending cycle, spawns one
`claude -p /goal` child per cycle, waits for each child's `result.json`,
narrates the result so the evaluator can see it, and loops until done.

## How it works

```
top:   claude -p "/goal <outer condition>"
         │
         ▼ (outer Claude reads spec, picks next cycle, spawns child)
cycle: claude -p "/goal <per-cycle condition>"
         │
         ▼ (cycle child: test-author → red → 6 workers → score → reviewers → consolidator)
       result.json
```

`/goal` is one-goal-per-session by design. Session boundaries sidestep the
limit — each `claude -p` gets a fresh session with its own evaluator.

Inside a cycle:

1. **test-author** writes `tests.json` + the actual test files for the cycle's
   acceptance criteria.
2. **red gate**: `cycle-tests-pass.sh red` proves the tests fail correctly
   (inverted exit code catches tautological tests).
3. **6 implementer-workers** dispatch in parallel, each writing an independent
   candidate under `cycles/<id>/green/candidates/worker-K/`.
4. **Score and pick** the simplest passer (LOC → files → complexity proxy);
   apply via rsync.
5. **N reviewers** dispatch in parallel. Count, model (`opus` or `sonnet`), and
   per-reviewer dimension all come from `spec.md ## Reviewer Config`.
6. **consolidator** clusters findings by file+line proximity, verifies
   critical/high against source, writes `review.md` with a machine-readable
   `Cluster summary` block.
7. **result.json** is written with `status: pass | fail` + `review_clusters`.
   The cycle child's `/goal` clears once status is pass and critical=0.

Sequential cycles run until the outer goal clears (every cycle pass) or hits
its turn cap.

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

The **length of `dimensions`** is the reviewer count — no separate `count:`
field. Want two security reviewers? List `security` twice.

Curated menu (planner Phase 1.5 multi-select):

- **Tier 1** — `correctness`, `design`, `error-handling`, `simplicity`,
  `tests-vs-impl`, `security`
- **Tier 2** — `performance`, `naming-readability`, `dependency-hygiene`,
  `type-safety`, `concurrency`, `observability`
- **Tier 3** (declare per-project, not shown by default) — `sui-move-idioms`,
  `frontend-a11y`, `api-contract-stability`

See `agents/reviewer.md` for the dimension-to-lens map.

## The one hook

`hooks/forge-guard.mjs` blocks Edit/Write/Bash writes that would weaken the
test suite during green phase. Without it, `/goal "tests pass"` would happily
mutate tests instead of the implementation — the evaluator can only see what
ends up in the transcript and cannot diff against a baseline.

Coverage:

- Edits/Writes to any path listed in `tests.json[*].test_file`.
- Edits/Writes to `.forge/state.json` and `.forge/cycles/<id>/tests.json`
  themselves (the anchors the rule reads from).
- Bash file-writes via `>`, `>>`, `&>`, `>|`, `2>`, `| tee`, `cp`, `mv`,
  `install`, `cp -t <dir>`, GNU + BSD `sed -i`, `perl -i`, `ruby -i`,
  `awk -i inplace`, `python -c open(...,"w")`, `dd of=`, `truncate`, `ln -sf`,
  `rm`, and `sh -c` / `bash -c` / `eval` / here-string invocations referencing
  any of the above.

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
│   ├── forge.sh            # top-level launcher
│   ├── cycle-init.sh       # scaffold a cycle dir
│   ├── cycle-validate.sh   # schema validator
│   ├── cycle-tests-pass.sh # red/green truth gate (inverts at red)
│   ├── forge-status.sh     # dashboard
│   └── deploy.sh
├── skills/code-forge/SKILL.md
├── templates/spec.md.template
├── docs/
│   ├── index.html          # GitHub Pages landing
│   └── goal-integration.md # full protocol (outer + cycle child)
└── tests/
    ├── smoke.sh            # 90 assertions
    └── fixtures/
```

## Deploy

The canonical install is the submodule at `~/.claude/code-forge/`. Sync after
local changes with:

```bash
bash scripts/deploy.sh             # rsync repo → install
bash scripts/deploy.sh --dry-run   # show what would change
bash scripts/deploy.sh --check     # exit 0 if in sync
```

For the submodule install, `git pull` inside the submodule (or
`git submodule update --remote --merge code-forge` from the parent dotclaude
repo) is enough — no rsync needed.

## Self-test

```bash
bash tests/smoke.sh   # 90 assertions; exits 0 iff every check passes
# Or from inside Claude Code:
/forge-smoke
```

## Related

- [`sui-pilot`](https://github.com/alilloig/sui-pilot) — source of the
  script-coordinated parallel-review pattern (`move-pr-review` skill).
- [`codex-bridge`](https://github.com/alilloig/codex-bridge) — Codex MCP
  integration used by the planner's spec/e2e cross-checks.
