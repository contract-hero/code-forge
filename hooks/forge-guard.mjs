#!/usr/bin/env node

/**
 * Forge Guard v2 — Programmatic enforcement for the Code Forge v2 protocol.
 *
 * Carries forward the four original rig invariants (contract-exists,
 * evaluation-passed, phase-transition, codex-gates) and adds four new v2
 * invariants targeting TDD discipline and parallel-review correctness.
 *
 * Original invariants (kept):
 *   1. No implementation without a contract.
 *   2. No advancing past a failed cycle review.
 *   3. Phase transitions must follow order.
 *   4. Codex gates cannot be silently skipped (unless --light).
 *
 * New v2 invariants (§8 of code-forge-v2-spec.md):
 *   5. PreToolUse(Edit) — block edits to test files during green phase
 *      (anti-weakening rule from 05-tdd.md).
 *   6. PreToolUse(Task) — block second `reviewer` Agent dispatch >5 seconds
 *      after a previous reviewer's subagent-N.json appeared. Forces
 *      single-turn fan-out during consolidated-review.
 *   7. PreToolUse(Edit/Write) — post-cycle-pass freeze: block edits to files
 *      named in a sealed cycle's contract.md until next cycle's contract
 *      phase begins.
 *   8. PostToolUse(Edit/Write) — auto-fire cycle-validate.sh on edits to
 *      tests.json, contract.md, or subagent-*.json.
 *
 * Note: Rule 2 from §8 (red-phase exit-code requirement) is implemented in
 * scripts/cycle-tests-pass.sh, not here — the script IS the gate. See its
 * inversion-for-red logic.
 *
 * State source of truth: .forge/state.json (v2). Falls back to .forge/status.md
 * YAML frontmatter (v1/rig) when state.json is absent, for transitional repos.
 */

import { readFileSync, existsSync, statSync, readdirSync } from "node:fs";
import { resolve, dirname, basename, join } from "node:path";
import { execFileSync } from "node:child_process";

// --- Phase ordering ---

const PHASE_ORDER = [
  "intent",
  "exploration",
  "prompt-refinement",
  "agent-detection",
  "specification",
  "spec-critique",
  "cycle-planning",
  "cycle",
  // v2 sub-phases inside cycle:
  "contract",
  "test-list",
  "red",
  "green",
  "consolidated-review",
  "done",
];

// --- Helpers ---

function parseStdin() {
  try {
    const raw = readFileSync(0, "utf8");
    if (!raw.trim()) return null;
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function readYamlFrontmatter(filePath) {
  try {
    const content = readFileSync(filePath, "utf8");
    const match = content.match(/^---\n([\s\S]*?)\n---/);
    if (!match) return null;
    const pairs = {};
    for (const line of match[1].split("\n")) {
      const kv = line.match(/^(\w[\w-]*):\s*"?([^"]*)"?\s*$/);
      if (kv) pairs[kv[1]] = kv[2].trim();
    }
    return pairs;
  } catch {
    return null;
  }
}

function readState(forgeRoot) {
  if (!forgeRoot) return null;
  // Prefer v2 state.json; fall back to v1 status.md
  const stateJson = resolve(forgeRoot, "state.json");
  if (existsSync(stateJson)) {
    try {
      return JSON.parse(readFileSync(stateJson, "utf8"));
    } catch {
      return null;
    }
  }
  const statusMd = resolve(forgeRoot, "status.md");
  if (existsSync(statusMd)) {
    return readYamlFrontmatter(statusMd);
  }
  return null;
}

function findForgeRoot(filePath) {
  const match = filePath?.match(/^(.+\/\.forge)\//);
  if (match) return match[1];
  if (filePath?.endsWith("/.forge")) return filePath;
  return null;
}

function extractCycleNumber(filePath) {
  const match = filePath?.match(/\.forge\/cycles\/(\d+)\//);
  return match ? parseInt(match[1], 10) : null;
}

function isForgeArtifact(filePath) {
  return filePath && filePath.includes(".forge/");
}

function listFilesInContract(contractPath) {
  // Extract bullet-list paths from the "## Files" section of contract.md.
  // Format expected: "- path/to/file.ext — description"
  if (!existsSync(contractPath)) return [];
  try {
    const content = readFileSync(contractPath, "utf8");
    const m = content.match(/^## Files\s*\n([\s\S]*?)(?=\n## |\n$)/m);
    if (!m) return [];
    const paths = [];
    for (const line of m[1].split("\n")) {
      const lm = line.match(/^\s*-\s+([^\s—\-]+)/);
      if (lm) paths.push(lm[1].trim());
    }
    return paths;
  } catch {
    return [];
  }
}

function loadTestsJson(cycleDir) {
  const testsPath = resolve(cycleDir, "tests.json");
  if (!existsSync(testsPath)) return [];
  try {
    return JSON.parse(readFileSync(testsPath, "utf8"));
  } catch {
    return [];
  }
}

// --- ORIGINAL invariants (kept from rig, adapted for v2) ---

/**
 * Phase-transition check (advisory). Fires on state.json or status.md writes.
 * Verifies that the new phase has its prerequisite artifacts.
 */
function checkPhaseTransitionV2(filePath, forgeRoot) {
  if (!forgeRoot) return null;
  const isStateWrite =
    filePath?.endsWith("/state.json") || filePath?.endsWith("/status.md");
  if (!isStateWrite) return null;

  const state = readState(forgeRoot);
  if (!state || !state.phase) return null;
  const newPhase = state.phase;

  const missingPrereqs = [];
  if (newPhase === "specification" || newPhase === "spec-critique") {
    if (!existsSync(resolve(forgeRoot, "intent.md"))) {
      missingPrereqs.push("intent.md (Phase 0: Intent Sharpening)");
    }
  }
  if (newPhase === "specification") {
    if (!existsSync(resolve(forgeRoot, "planning-prompt.md"))) {
      missingPrereqs.push("planning-prompt.md (Phase 1: Prompt Refinement)");
    }
  }
  if (newPhase === "spec-critique") {
    if (!existsSync(resolve(forgeRoot, "spec.md"))) {
      missingPrereqs.push("spec.md (Phase 2: Specification)");
    }
  }
  if (newPhase === "cycle-planning" || newPhase === "cycle" || newPhase === "contract") {
    if (!existsSync(resolve(forgeRoot, "spec.md"))) {
      missingPrereqs.push("spec.md (Phase 2: Specification)");
    }
  }
  if (newPhase === "cycle" || newPhase === "contract") {
    if (!existsSync(resolve(forgeRoot, "cycle-plan.md"))) {
      missingPrereqs.push("cycle-plan.md (Phase 3: Cycle Planning)");
    }
  }

  if (missingPrereqs.length === 0) return null;
  return [
    "[ADVISE] Forge Guard: possible phase skip detected",
    "",
    `State updated to phase "${newPhase}" but prerequisite artifacts are missing:`,
    ...missingPrereqs.map((p) => `  - ${p}`),
    "",
    "Review the forge workflow and ensure all prior phases completed.",
  ].join("\n");
}

/**
 * Codex-gate advisory. Fires on state.json or status.md writes.
 */
function checkCodexGatesV2(filePath, forgeRoot) {
  if (!forgeRoot) return null;
  const isStateWrite =
    filePath?.endsWith("/state.json") || filePath?.endsWith("/status.md");
  if (!isStateWrite) return null;

  const state = readState(forgeRoot);
  if (!state) return null;

  const lightMode =
    state.light_mode === true ||
    state.light_mode === "true" ||
    state["light-mode"] === "true";
  const phase = state.phase || "";
  const currentCycle = parseInt(state.current_cycle || state.currentCycle || "0", 10);

  const missing = [];
  if (
    phase === "specification" ||
    phase === "spec-critique" ||
    phase === "cycle-planning" ||
    phase === "cycle" ||
    phase === "contract"
  ) {
    if (!existsSync(resolve(forgeRoot, "prompt-evolution.md"))) {
      missing.push("prompt-evolution.md (Gate G1: Prompt Refinement with Codex)");
    }
  }
  if (
    !lightMode &&
    (phase === "cycle-planning" || phase === "cycle" || phase === "contract")
  ) {
    if (!existsSync(resolve(forgeRoot, "spec-critique.md"))) {
      missing.push("spec-critique.md (Gate G2: Spec Critique by Codex)");
    }
  }
  // G5: codex-review for completed previous cycles (v2 keeps the same gate)
  if ((phase === "cycle" || phase === "contract") && currentCycle > 1) {
    for (let i = 1; i < currentCycle; i++) {
      const reviewPath = resolve(forgeRoot, "cycles", String(i), "codex-review.md");
      if (!existsSync(reviewPath)) {
        missing.push(`cycles/${i}/codex-review.md (Gate G5: Codex Cycle Review)`);
      }
    }
  }

  if (missing.length === 0) return null;
  const prefix = lightMode
    ? "[ADVISE] Forge Guard: Codex artifacts missing (light mode — may be expected)"
    : "[ADVISE] Forge Guard: Codex gate artifacts missing";
  return [
    prefix,
    "",
    "The following Codex review artifacts were not found:",
    ...missing.map((m) => `  - ${m}`),
    "",
    lightMode
      ? "Light mode is active — some Codex gates are optional."
      : "The forge protocol requires Codex cross-checking at each gate.",
  ].join("\n");
}

// --- Hard-block invariants (kept from rig) ---

function checkContractExists(filePath) {
  if (!filePath.match(/\.forge\/cycles\/\d+\/(implementation-notes\.md|green\.log)$/)) return null;
  const cycleN = extractCycleNumber(filePath);
  if (cycleN === null) return null;
  const forgeRoot = findForgeRoot(filePath);
  const cycleDir = dirname(filePath);
  const contractPath = forgeRoot
    ? resolve(forgeRoot, "cycles", String(cycleN), "contract.md")
    : resolve(cycleDir, "contract.md");
  if (existsSync(contractPath)) return null;
  return [
    "[BLOCK] Forge Guard: missing contract",
    "",
    `Cannot write implementation artifact for cycle ${cycleN} — no contract found.`,
    `Expected: ${contractPath}`,
    "",
    "The forge protocol requires a negotiated completion contract before",
    "implementation begins. Complete the contract phase first.",
  ].join("\n");
}

function checkPreviousCyclePassed(filePath) {
  const cycleN = extractCycleNumber(filePath);
  if (cycleN === null || cycleN <= 1) return null;
  if (!filePath.match(/\.forge\/cycles\/\d+\/contract\.md$/)) return null;
  const forgeRoot = findForgeRoot(filePath);
  const prevCycle = cycleN - 1;
  const consolidatedPath = forgeRoot
    ? resolve(forgeRoot, "cycles", String(prevCycle), "_consolidated.json")
    : resolve(dirname(dirname(filePath)), String(prevCycle), "_consolidated.json");
  // v1/rig fallback: check evaluation.md too
  const evalPath = forgeRoot
    ? resolve(forgeRoot, "cycles", String(prevCycle), "evaluation.md")
    : resolve(dirname(dirname(filePath)), String(prevCycle), "evaluation.md");

  if (!existsSync(consolidatedPath) && !existsSync(evalPath)) {
    return [
      `[BLOCK] Forge Guard: cycle ${prevCycle} not reviewed`,
      "",
      `Cannot start cycle ${cycleN} — no _consolidated.json or evaluation.md for cycle ${prevCycle}.`,
      "",
      "Each cycle must complete consolidated-review before the next begins.",
    ].join("\n");
  }

  // If v2 consolidated artifact exists, check pass criteria
  if (existsSync(consolidatedPath)) {
    try {
      const arr = JSON.parse(readFileSync(consolidatedPath, "utf8"));
      const critical = arr.filter((c) => c.max_severity === "critical").length;
      const disputed = arr.filter((c) => c.disputed_severity === true).length;
      if (critical > 0 || disputed > 0) {
        return [
          `[BLOCK] Forge Guard: cycle ${prevCycle} did not pass review`,
          "",
          `Cannot start cycle ${cycleN} — cycle ${prevCycle} has ${critical} critical and ${disputed} disputed clusters.`,
          `Run: bash scripts/cycle-pass.sh ${dirname(consolidatedPath)}`,
          "",
          "Address findings or split disputed clusters before advancing.",
        ].join("\n");
      }
    } catch { /* fall through to evaluation.md check */ }
  }

  // v1 fallback
  if (existsSync(evalPath)) {
    const fm = readYamlFrontmatter(evalPath);
    if (fm && (fm.verdict || "").toUpperCase() !== "PASS") {
      return [
        `[BLOCK] Forge Guard: cycle ${prevCycle} evaluation is ${fm.verdict || "UNKNOWN"}`,
        "",
        `Cannot start cycle ${cycleN} — cycle ${prevCycle} has not passed evaluation.`,
      ].join("\n");
    }
  }

  return null;
}

// --- NEW v2 invariants ---

/**
 * Rule 5: Block test-file edits during green phase.
 * Prevents the implementer from weakening tests to make them pass.
 */
function checkTestFileEditDuringGreen(filePath, forgeRoot) {
  if (!isForgeArtifact(filePath)) {
    // Test file might live outside .forge/. Need to consult tests.json.
    if (!forgeRoot) {
      // Can't determine forgeRoot from filePath directly; try cwd().
      const possibleForge = resolve(process.cwd(), ".forge");
      if (!existsSync(possibleForge)) return null;
      forgeRoot = possibleForge;
    }
  }

  const state = readState(forgeRoot);
  if (!state) return null;

  // Phase check: must be green (or sub-phase of cycle that means green)
  const phase = state.phase || "";
  if (phase !== "green") return null;

  const cycleN = state.current_cycle || state.currentCycle || 1;
  const cycleDir = resolve(forgeRoot, "cycles", String(cycleN));
  const tests = loadTestsJson(cycleDir);
  if (tests.length === 0) return null;

  // Resolve filePath to repo-relative for comparison; tests.json target_files
  // are typically repo-relative.
  const repoRoot = resolve(forgeRoot, "..");
  const relPath = filePath.startsWith(repoRoot + "/")
    ? filePath.slice(repoRoot.length + 1)
    : filePath;

  const targets = new Set(tests.map((t) => t.target_file).filter(Boolean));
  if (!targets.has(relPath) && !targets.has(filePath)) return null;

  return [
    "[BLOCK] Forge Guard: test-file edit blocked during green phase",
    "",
    `Cycle ${cycleN} is in 'green' phase. The implementer cannot edit test files`,
    `during this phase — that is the anti-weakening rule.`,
    "",
    `Blocked path: ${relPath}`,
    `Listed in:    ${cycleDir}/tests.json`,
    "",
    "If the tests are genuinely wrong, return to the test-list phase and",
    "amend tests.json with the orchestrator's review. Do not edit tests in green.",
  ].join("\n");
}

/**
 * Rule 6: Parallel reviewer fan-out enforcement.
 * Block second `reviewer` Agent dispatch if previous reviewer's output
 * appeared more than 5 seconds ago — that means dispatch is serial, not
 * parallel.
 */
function checkParallelReviewerFanout(toolInput, forgeRoot) {
  if (!toolInput) return null;
  const subagentType = toolInput.subagent_type || "";
  const desc = toolInput.description || "";
  const prompt = toolInput.prompt || "";

  // Heuristic: this is a reviewer dispatch if subagent_type or
  // description/prompt mentions "reviewer" + "dimension" / "subagent-".
  const isReviewer =
    subagentType.includes("reviewer") ||
    /reviewer.*\bdimension\b/i.test(desc) ||
    /subagent-\d+\.json/.test(prompt);
  if (!isReviewer) return null;

  if (!forgeRoot) {
    const possibleForge = resolve(process.cwd(), ".forge");
    if (!existsSync(possibleForge)) return null;
    forgeRoot = possibleForge;
  }

  const state = readState(forgeRoot);
  if (!state) return null;
  const phase = state.phase || "";
  if (phase !== "consolidated-review") return null;

  const cycleN = state.current_cycle || state.currentCycle || 1;
  const reviewersDir = resolve(forgeRoot, "cycles", String(cycleN), "reviewers");
  if (!existsSync(reviewersDir)) return null;

  // Find any subagent-*.json that already exists
  let entries = [];
  try {
    entries = readdirSync(reviewersDir).filter((n) => /^subagent-\d+\.json$/.test(n));
  } catch {
    return null;
  }
  if (entries.length === 0) return null;

  // If any output is older than 5 seconds, this dispatch is serial
  const now = Date.now();
  const FIVE_SEC = 5000;
  for (const f of entries) {
    const p = join(reviewersDir, f);
    try {
      const m = statSync(p).mtimeMs;
      if (now - m > FIVE_SEC) {
        return [
          "[BLOCK] Forge Guard: serial reviewer dispatch detected",
          "",
          `Cycle ${cycleN} is in consolidated-review and ${entries.length} reviewer output(s)`,
          `already exist. The most recent landed >${Math.round((now - m) / 1000)}s ago.`,
          "",
          `Dispatching another reviewer now is serial, not parallel.`,
          "",
          "Reviewers must be dispatched in a single assistant turn (N parallel",
          "Agent tool calls in one message) so they reason independently of",
          "each other's outputs. See spec §4.3 for why this is load-bearing.",
        ].join("\n");
      }
    } catch { /* skip */ }
  }
  return null;
}

/**
 * Rule 7: Post-cycle freeze.
 * Once cycle N's _consolidated.json is sealed (cycle-pass.sh would return 0),
 * block edits to files listed in cycle N's contract.md until cycle N+1's
 * contract phase begins.
 */
function checkPostCycleFreeze(filePath, forgeRoot) {
  if (!filePath || !forgeRoot) {
    const possibleForge = resolve(process.cwd(), ".forge");
    if (!existsSync(possibleForge)) return null;
    forgeRoot = possibleForge;
  }

  const state = readState(forgeRoot);
  if (!state) return null;
  const phase = state.phase || "";
  // Only enforce when we're between cycles (cycle finished review, not yet
  // started next contract phase). If state.phase indicates a new cycle's
  // contract has begun, the freeze is lifted.
  // Heuristic: if phase is "consolidated-review" or "cycle" with cycle_status
  // "complete", we are between cycles.
  const cycleStatus = state.cycle_status || state.cycleStatus || "";
  const inFreeze = phase === "consolidated-review" || cycleStatus === "complete";
  if (!inFreeze) return null;

  const currentCycle = parseInt(state.current_cycle || state.currentCycle || 0, 10);
  if (!currentCycle) return null;

  const cycleDir = resolve(forgeRoot, "cycles", String(currentCycle));
  const consolidated = resolve(cycleDir, "_consolidated.json");
  if (!existsSync(consolidated)) return null;

  const contractPath = resolve(cycleDir, "contract.md");
  const protectedFiles = listFilesInContract(contractPath);
  if (protectedFiles.length === 0) return null;

  // Resolve filePath to repo-relative
  const repoRoot = resolve(forgeRoot, "..");
  const relPath = filePath.startsWith(repoRoot + "/")
    ? filePath.slice(repoRoot.length + 1)
    : filePath;

  if (!protectedFiles.includes(relPath)) return null;

  return [
    "[BLOCK] Forge Guard: post-cycle freeze",
    "",
    `Cycle ${currentCycle} has completed review. Files in its contract are`,
    `frozen until the next cycle's contract phase begins.`,
    "",
    `Frozen path: ${relPath}`,
    `Contract:    ${contractPath}`,
    "",
    "Spin a new cycle (write cycles/N+1/contract.md) before editing this file.",
  ].join("\n");
}

/**
 * Rule 8: Auto-fire cycle-validate.sh on edits to schema-bearing artifacts.
 * Advisory (PostToolUse) — surfaces validation failures immediately rather
 * than blocking the edit.
 */
function fireValidateOnSchemaArtifact(filePath, forgeRoot) {
  if (!filePath) return null;
  const name = basename(filePath);
  const isSchemaArtifact =
    name === "tests.json" ||
    name === "contract.md" ||
    /^subagent-\d+\.json$/.test(name);
  if (!isSchemaArtifact) return null;

  const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT;
  if (!pluginRoot) return null;
  const validator = resolve(pluginRoot, "scripts/cycle-validate.sh");
  if (!existsSync(validator)) return null;

  try {
    execFileSync("bash", [validator, filePath], {
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 4000,
    });
    return null; // OK
  } catch (e) {
    const stderr = e.stderr ? e.stderr.toString() : "";
    const stdout = e.stdout ? e.stdout.toString() : "";
    return [
      `[ADVISE] Forge Guard: cycle-validate.sh failed for ${name}`,
      "",
      stdout.trim(),
      stderr.trim(),
      "",
      "The artifact's schema does not match. The agent that wrote it should",
      "re-emit a corrected version before the next phase begins.",
    ].filter(Boolean).join("\n");
  }
}

// --- Main ---

async function main() {
  const hookType = process.argv[2]; // "pre-tool-use" or "post-tool-use"
  const input = parseStdin();
  if (!input) process.exit(0);

  const toolName = input.tool_name || "";
  const toolInput = input.tool_input || {};
  const filePath = toolInput.file_path;
  const forgeRoot = filePath ? findForgeRoot(filePath) : null;

  if (hookType === "pre-tool-use") {
    const violations = [];

    // Original invariants — only relevant for Edit/Write of forge artifacts
    if ((toolName === "Edit" || toolName === "Write") && isForgeArtifact(filePath)) {
      violations.push(checkContractExists(filePath));
      violations.push(checkPreviousCyclePassed(filePath));
    }

    // v2 rule 5 — test-file edit during green (file may be outside .forge/)
    if (toolName === "Edit" || toolName === "Write") {
      violations.push(checkTestFileEditDuringGreen(filePath, forgeRoot));
      violations.push(checkPostCycleFreeze(filePath, forgeRoot));
    }

    // v2 rule 6 — parallel reviewer fan-out (Task tool dispatching subagent)
    if (toolName === "Task" || toolName === "Agent") {
      violations.push(checkParallelReviewerFanout(toolInput, forgeRoot));
    }

    const real = violations.filter(Boolean);
    if (real.length > 0) {
      process.stderr.write(real.join("\n\n---\n\n") + "\n");
      process.exit(2);
    }
    process.exit(0);
  }

  if (hookType === "post-tool-use") {
    const advisories = [];

    // Original invariants (advisory) — phase transition + Codex gates fire
    // on state.json / status.md writes.
    if ((toolName === "Edit" || toolName === "Write") && filePath) {
      // forgeRoot from filePath; if unset, derive from cwd
      let root = forgeRoot;
      if (!root) {
        const candidate = resolve(process.cwd(), ".forge");
        if (existsSync(candidate)) root = candidate;
      }
      advisories.push(checkPhaseTransitionV2(filePath, root));
      advisories.push(checkCodexGatesV2(filePath, root));
    }

    // v2 rule 8 — auto-fire validation
    if ((toolName === "Edit" || toolName === "Write") && filePath) {
      advisories.push(fireValidateOnSchemaArtifact(filePath, forgeRoot));
    }

    const real = advisories.filter(Boolean);
    if (real.length > 0) {
      process.stderr.write(real.join("\n\n---\n\n") + "\n");
    }
    process.exit(0);
  }

  process.exit(0);
}

main().catch(() => process.exit(0));
