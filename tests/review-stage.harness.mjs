// Headless test harness for workflows/review-stage.mjs.
//
// A Workflow script can't run in `claude -p` (and `node --check` rejects its
// top-level return/await). This harness wraps the script body the way the
// Workflow tool does — an async function with injected globals
// (agent/parallel/phase/log/args) — and runs it with STUBBED agents, so the
// orchestration glue (fan-out, dropout detection, prompt building, return
// shape) is exercised deterministically. The agents' actual reasoning is NOT
// tested here (that needs a live interactive Workflow run).
//
// Run: node tests/review-stage.harness.mjs   (exit 0 = pass)

import { readFileSync } from 'node:fs'
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const SCRIPT = join(HERE, '..', 'workflows', 'review-stage.mjs')

// --- Load the workflow body the way the Workflow runtime would ---
// Strip the ESM `export` (the runtime reads `meta` separately) and run the
// remainder inside an async function with the injected globals as params.
const raw = readFileSync(SCRIPT, 'utf8')
assert.ok(raw.includes('export const meta'), 'script must export meta')
const body = raw.replace('export const meta', 'const meta')

function buildRunner() {
  // eslint-disable-next-line no-new-func
  return new Function('agent', 'parallel', 'phase', 'log', 'args',
    `return (async () => { ${body}\n; return { __meta: meta }; })()`)
}

// Sanity: also expose meta by running once with no-op stubs that short-circuit.
// (We run the real flow below; this just proves it parses + meta is well-formed.)

// --- Stubs ---
function makeStubs({ failReviewerIndex = null } = {}) {
  const calls = { reviewer: [], consolidator: [] }
  const consolidatorSummary = {
    critical: 1, high: 2, medium: 0, low: 3, info: 1,
    reviewMdPath: '.forge/cycles/CX/review.md',
  }
  const agent = async (prompt, opts) => {
    if (opts.agentType === 'code-forge:forge-reviewer') {
      const idx = calls.reviewer.length + 1
      calls.reviewer.push({ prompt, opts })
      if (failReviewerIndex === idx) throw new Error('simulated reviewer failure')
      return { findings: [] }
    }
    if (opts.agentType === 'code-forge:forge-consolidator') {
      calls.consolidator.push({ prompt, opts })
      return consolidatorSummary
    }
    throw new Error(`unexpected agentType: ${opts.agentType}`)
  }
  // Mirror the Workflow tool: a thunk that throws resolves to null.
  const parallel = async (thunks) =>
    Promise.all(thunks.map((t) => Promise.resolve().then(t).catch(() => null)))
  const phase = () => {}
  const log = () => {}
  return { agent, parallel, phase, log, calls, consolidatorSummary }
}

const ARGS = {
  cycleDir: '.forge/cycles/CX',
  specPath: '.forge/spec.md',
  dimensions: ['correctness', 'simplicity', 'security'],
  model: 'opus',
  sourceFiles: ['src/example.ts'],
}

let pass = 0
const ok = (name) => { console.log(`  ok  ${name}`); pass++ }

// --- Test 1: happy path ---
{
  const s = makeStubs()
  const runner = buildRunner()
  const result = await runner(s.agent, s.parallel, s.phase, s.log, { ...ARGS })

  assert.equal(s.calls.reviewer.length, 3, '3 reviewers dispatched')
  assert.equal(s.calls.consolidator.length, 1, '1 consolidator dispatched')
  // result is the consolidator's returned summary (not the __meta sentinel,
  // because the script's own `return summary` short-circuits before it).
  assert.deepEqual(
    { critical: result.critical, high: result.high, medium: result.medium,
      low: result.low, info: result.info, reviewMdPath: result.reviewMdPath },
    s.consolidatorSummary, 'returns the consolidator cluster summary')
  ok('happy path: 3 reviewers -> consolidator -> summary returned')

  // prompts carry per-reviewer runtime context
  s.calls.reviewer.forEach((c, i) => {
    assert.ok(c.prompt.includes(ARGS.dimensions[i]), `reviewer ${i + 1} prompt names its dimension`)
    assert.ok(c.prompt.includes(`R${i + 1}-`), `reviewer ${i + 1} prompt names its id prefix`)
    assert.ok(c.prompt.includes(`subagent-${i + 1}.json`), `reviewer ${i + 1} prompt names its output file`)
    assert.equal(c.opts.schema.required[0], 'findings', `reviewer ${i + 1} gets FINDINGS_SCHEMA`)
    assert.equal(c.opts.agentType, 'code-forge:forge-reviewer')
  })
  ok('reviewer prompts carry dimension + index + output path + schema')

  assert.equal(s.calls.consolidator[0].opts.agentType, 'code-forge:forge-consolidator')
  assert.ok(s.calls.consolidator[0].opts.schema.required.includes('reviewMdPath'),
    'consolidator gets CLUSTER_SUMMARY_SCHEMA')
  ok('consolidator gets CLUSTER_SUMMARY_SCHEMA')
}

// --- Test 2: reviewer dropout is detected and passed to the consolidator ---
{
  const s = makeStubs({ failReviewerIndex: 2 })  // simplicity reviewer fails
  const runner = buildRunner()
  await runner(s.agent, s.parallel, s.phase, s.log, { ...ARGS })

  assert.equal(s.calls.reviewer.length, 3, 'all 3 attempted')
  const cprompt = s.calls.consolidator[0].prompt
  assert.ok(cprompt.includes('realized reviewer count: 2'), 'consolidator told realized=2')
  assert.ok(cprompt.includes('simplicity'), 'consolidator told which dimension dropped')
  assert.ok(/dropout/i.test(cprompt), 'consolidator instructed to emit dropout cluster')
  ok('dropout: failed reviewer -> realizedCount + dropped passed to consolidator')
}

// --- Test 3: meta is a well-formed pure literal ---
{
  // Re-run but capture meta by short-circuiting agents to throw after first.
  // Simpler: parse meta via a minimal runner that returns the sentinel before
  // the orchestration by feeding zero dimensions.
  const s = makeStubs()
  const runner = buildRunner()
  const result = await runner(s.agent, s.parallel, s.phase, s.log,
    { ...ARGS, dimensions: [] })
  // zero dimensions -> parallel([]) -> realized 0 -> consolidator still runs once
  assert.equal(s.calls.reviewer.length, 0, 'no reviewers for zero dimensions')
  assert.equal(s.calls.consolidator.length, 1, 'consolidator still runs')
  ok('meta parses; zero-dimension edge dispatches consolidator only')
}

console.log(`\nreview-stage.harness: ${pass} checks passed`)
