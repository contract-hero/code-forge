// Code Forge — review-stage Workflow (Workflows-native, PR #1).
//
// Ports the read-only reviewer -> consolidator stage of one cycle onto the
// Claude Code Workflow tool. Invoked by the /forge skill (NOT a `claude -p`
// child — Workflows are unavailable in headless mode). Read-only: reviewers
// analyze source and emit findings; the consolidator only writes review.md.
//
// Design: docs/superpowers/specs/2026-05-29-review-stage-workflow-design.md
//
// args: {
//   cycleDir,    e.g. ".forge/cycles/C1"   (reviewers/ lives under here)
//   specPath,    e.g. ".forge/spec.md"
//   dimensions,  ["correctness","simplicity","security", ...] from ## Reviewer Config
//   model,       "opus" | "sonnet"          from ## Reviewer Config
//   sourceFiles, [...]                       the cycle's files_affected
// }
// returns: { critical, high, medium, low, info, reviewMdPath }

export const meta = {
  name: 'forge-review-stage',
  description: 'Dimensional reviewers + consolidation for one code-forge cycle',
  phases: [
    { title: 'Review' },
    { title: 'Consolidate' },
  ],
}

// --- Schemas (single source of truth; mirror cycle-validate.sh validate_reviewer) ---

const SEVERITY = ['critical', 'high', 'medium', 'low', 'info']
const CONFIDENCE = ['high', 'medium', 'low']
const CATEGORY = [
  'correctness', 'design', 'error-handling', 'simplicity', 'tests-vs-impl',
  'dependencies', 'security', 'performance', 'documentation', 'build',
  'naming-readability', 'dependency-hygiene', 'type-safety', 'concurrency',
  'observability', 'sui-move-idioms', 'frontend-a11y', 'api-contract-stability',
]

// Object-wrapped so the StructuredOutput root is an object (not a bare array).
const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'title', 'severity', 'category', 'file', 'line_range',
          'description', 'impact', 'recommendation', 'evidence', 'confidence'],
        properties: {
          id: { type: 'string', pattern: '^R\\d+-\\d{3}$' },
          title: { type: 'string', minLength: 1 },
          severity: { type: 'string', enum: SEVERITY },
          category: { type: 'string', enum: CATEGORY },
          file: { type: 'string', minLength: 1 },
          line_range: { type: 'string', minLength: 1 },
          description: { type: 'string', minLength: 1 },
          impact: { type: 'string', minLength: 1 },
          recommendation: { type: 'string', minLength: 1 },
          evidence: { type: 'string', minLength: 1 },
          confidence: { type: 'string', enum: CONFIDENCE },
        },
      },
    },
  },
}

const CLUSTER_SUMMARY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['critical', 'high', 'medium', 'low', 'info', 'reviewMdPath'],
  properties: {
    critical: { type: 'integer', minimum: 0 },
    high: { type: 'integer', minimum: 0 },
    medium: { type: 'integer', minimum: 0 },
    low: { type: 'integer', minimum: 0 },
    info: { type: 'integer', minimum: 0 },
    reviewMdPath: { type: 'string', minLength: 1 },
  },
}

// --- Prompt builders (runtime context only; the agentType .md is the system prompt) ---

function reviewerPrompt({ cycleDir, specPath, dimension, reviewerIndex }) {
  return [
    `You are reviewing code-forge cycle deliverables.`,
    `- dimension: ${dimension}`,
    `- reviewer_index: ${reviewerIndex}  (your finding ids are R${reviewerIndex}-NNN; output file subagent-${reviewerIndex}.json)`,
    `- cycle directory: ${cycleDir}`,
    `- spec.md: ${specPath}`,
    ``,
    `Follow your standard procedure. Review ONLY through the "${dimension}" lens.`,
    `Do two things with the SAME findings array, this turn:`,
    `  1. Write it to ${cycleDir}/reviewers/subagent-${reviewerIndex}.json (a JSON array, your usual on-disk format, for forensics).`,
    `  2. Return it as the structured object { "findings": [ ... ] } (schema-enforced).`,
    `An empty findings array is acceptable — do not invent findings.`,
  ].join('\n')
}

function consolidatorPrompt({ cycleDir, specPath, realizedCount, dropped }) {
  const dropNote = dropped.length
    ? `Reviewer dropout: dimensions [${dropped.join(', ')}] produced NO output (process failure). Emit the synthetic "Reviewer dropout" cluster per your contract and cite reduced coverage in Methodology.`
    : `All configured reviewers produced output.`
  return [
    `You are the consolidator for code-forge cycle deliverables.`,
    `- cycle directory: ${cycleDir}`,
    `- spec.md: ${specPath}`,
    `- realized reviewer count: ${realizedCount}`,
    dropNote,
    ``,
    `Read every ${cycleDir}/reviewers/subagent-*.json from disk and follow your`,
    `standard procedure: cluster -> verify critical/high against source ->`,
    `split mega-clusters -> re-derive severity -> write ${cycleDir}/review.md`,
    `(keep the "## Cluster summary" block byte-stable).`,
    ``,
    `Then RETURN the structured object:`,
    `  { critical, high, medium, low, info, reviewMdPath } where the counts`,
    `  EXACTLY match your review.md Cluster summary block and reviewMdPath is`,
    `  "${cycleDir}/review.md". The /forge skill consumes this object directly.`,
  ].join('\n')
}

// --- Orchestration ---

// `args` should arrive as an object, but the Workflow tool may hand it over
// JSON-encoded (a documented footgun). Tolerate both, then validate shape so a
// bad invocation fails loud and early instead of deep in a .map().
const input = typeof args === 'string' ? JSON.parse(args) : args
if (!input || typeof input !== 'object') {
  throw new Error(`review-stage: args must be an object, got ${typeof args}`)
}
const { cycleDir, specPath, dimensions, model } = input
if (!Array.isArray(dimensions) || dimensions.length === 0) {
  throw new Error(`review-stage: args.dimensions must be a non-empty array (got ${JSON.stringify(dimensions)})`)
}
if (!cycleDir || !specPath) {
  throw new Error('review-stage: args.cycleDir and args.specPath are required')
}

phase('Review')
const results = await parallel(dimensions.map((dimension, i) => () =>
  agent(reviewerPrompt({ cycleDir, specPath, dimension, reviewerIndex: i + 1 }), {
    label: `review:${dimension}#${i + 1}`,
    phase: 'Review',
    model,
    agentType: 'code-forge:forge-reviewer',
    schema: FINDINGS_SCHEMA,
  })))

// parallel() yields null for a reviewer that errored -> deterministic dropout list.
const realizedCount = results.filter(Boolean).length
const dropped = dimensions.filter((_, i) => !results[i])
log(`Reviewers: ${realizedCount}/${dimensions.length} produced output` +
  (dropped.length ? ` (dropped: ${dropped.join(', ')})` : ''))

phase('Consolidate')
const summary = await agent(
  consolidatorPrompt({ cycleDir, specPath, realizedCount, dropped }), {
    label: 'consolidate',
    phase: 'Consolidate',
    model,
    agentType: 'code-forge:forge-consolidator',
    schema: CLUSTER_SUMMARY_SCHEMA,
  })

log(`Cluster summary: critical=${summary.critical} high=${summary.high} ` +
  `medium=${summary.medium} low=${summary.low} info=${summary.info}`)

return summary
