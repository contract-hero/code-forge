#!/usr/bin/env node

/**
 * Forge Guard (Option D edition).
 *
 * In Option D we keep exactly one hook rule: test files are read-only during
 * a cycle's green phase. Without it, /goal "tests pass" trivially weakens
 * tests instead of making the implementation pass. Every other former
 * forge-guard rule was either subsumed by the cycle child's /goal condition
 * (no advancing past a failed review, contract precedence, single-turn
 * fan-out, schema validation) or made obsolete by Option D's dropped surface
 * (Phase F remediation, post-cycle freeze, specialist routing).
 *
 * Rule (test immutability):
 *   - PreToolUse(Edit|Write) blocks edits to paths listed in the current
 *     cycle's tests.json `test_file` entries during green phase.
 *   - PreToolUse(Bash) heuristically blocks shell-level file writes
 *     (redirects, cp/mv, sed -i) that target the same test_file paths —
 *     closes the side door an implementer worker could otherwise use.
 *
 * The hook reads `.forge/state.json` to detect the green phase and the
 * current cycle. State schema is intentionally lax: any object with
 * `phase: "green"` and a `current_cycle` (string or number) works.
 *
 * Implementation notes:
 *   - The hook is realpath-aware on both sides of the path comparison.
 *     macOS resolves /var → /private/var via symlink; mktemp paths under
 *     test setups commonly cross it.
 *   - Workers stage candidates under .forge/cycles/<id>/green/candidates/
 *     worker-K/files/<repo-relative-path>. The hook peels that prefix so
 *     a worker's write to its own staged copy of a test_file still trips.
 */

import { readFileSync, existsSync, realpathSync } from "node:fs";
import { resolve, dirname, basename } from "node:path";

// --- Helpers --------------------------------------------------------------

function parseStdin() {
  try {
    const raw = readFileSync(0, "utf8");
    if (!raw.trim()) return null;
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function readState(forgeRoot) {
  if (!forgeRoot) return null;
  const stateJson = resolve(forgeRoot, "state.json");
  if (!existsSync(stateJson)) return null;
  try {
    return JSON.parse(readFileSync(stateJson, "utf8"));
  } catch {
    return null;
  }
}

function findForgeRoot(filePath) {
  const match = filePath?.match(/^(.+\/\.forge)\//);
  if (match) return match[1];
  if (filePath?.endsWith("/.forge")) return filePath;
  return null;
}

function isForgeArtifact(filePath) {
  return filePath && filePath.includes(".forge/");
}

// Realpath the longest-existing-ancestor prefix of `p`, then re-attach the
// missing trailing segments. Lets us canonicalize a path that names a planned
// write (file doesn't exist; intermediate dirs may also not exist), as long
// as at least one ancestor is on disk. When no ancestor exists, returns `p`
// unchanged.
function realpathLongestPrefix(p) {
  let cur = p;
  const tail = [];
  while (cur && cur !== "/" && cur !== ".") {
    try {
      return tail.length === 0
        ? realpathSync(cur)
        : resolve(realpathSync(cur), ...tail);
    } catch {
      tail.unshift(basename(cur));
      cur = dirname(cur);
    }
  }
  return p;
}

// Strip the absolute repoRoot prefix from filePath. Both sides go through
// realpathLongestPrefix() so /var → /private/var symlink crossings don't
// defeat the string-prefix compare.
function makeRepoRelative(filePath, repoRoot) {
  const realRoot = realpathLongestPrefix(repoRoot);
  const realFile = realpathLongestPrefix(filePath);
  return realFile.startsWith(realRoot + "/")
    ? realFile.slice(realRoot.length + 1)
    : realFile;
}

// Workers stage candidates under .forge/cycles/<id>/green/candidates/
// worker-K/files/<repo-relative-path>. Cycle IDs in Option D can be either
// strings (C1, C2) or numbers (1, 2) — the regex accepts both.
const CANDIDATE_STAGING_RE =
  /^\.forge\/cycles\/[^/]+\/green\/candidates\/worker-\d+\/files\/(.+)$/;

function peelCandidatePrefix(relPath) {
  const m = relPath.match(CANDIDATE_STAGING_RE);
  return m ? m[1] : null;
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

function resolveForgeRoot(forgeRoot) {
  if (forgeRoot) return forgeRoot;
  const candidate = resolve(process.cwd(), ".forge");
  return existsSync(candidate) ? candidate : null;
}

// --- The rule: test files read-only during green --------------------------

/**
 * Edit/Write block. Fires when:
 *   - .forge/state.json reports phase == "green"
 *   - The target file_path matches a test_file in the current cycle's
 *     tests.json (directly, or via candidate-staging prefix peel).
 */
function checkTestFileEditDuringGreen(filePath, forgeRoot) {
  if (!filePath) return null;
  const root = resolveForgeRoot(forgeRoot ?? findForgeRoot(filePath));
  if (!root) return null;

  const state = readState(root);
  if (!state || state.phase !== "green") return null;

  const cycleId = state.current_cycle ?? state.currentCycle ?? 1;
  const cycleDir = resolve(root, "cycles", String(cycleId));
  const tests = loadTestsJson(cycleDir);
  if (tests.length === 0) return null;

  const repoRoot = resolve(root, "..");
  const relPath = makeRepoRelative(filePath, repoRoot);
  const candidateResidue = peelCandidatePrefix(relPath);

  const testFiles = new Set(tests.map((t) => t.test_file).filter(Boolean));
  const directHit = testFiles.has(relPath);
  const candidateHit = candidateResidue && testFiles.has(candidateResidue);
  if (!directHit && !candidateHit) return null;

  return [
    "[BLOCK] Forge Guard: test-file edit blocked during green phase",
    "",
    `Cycle ${cycleId} is in 'green' phase. Tests are read-only here — the`,
    `anti-weakening rule from Option D's spec. The /goal evaluator only`,
    `judges what's in the transcript, so without this hook a "tests pass"`,
    `goal would happily mutate the tests instead of the implementation.`,
    "",
    `Blocked path: ${relPath}`,
    `Listed in:    ${cycleDir}/tests.json`,
    "",
    "If the tests are genuinely wrong, roll the cycle back to the test-list",
    "step and amend tests.json. Do not edit tests during green.",
  ].join("\n");
}

/**
 * Bash side-door block. The Edit/Write hook misses shell-level writes:
 *   - `echo … > tests/x.test.ts`
 *   - `cp src/foo tests/x.test.ts`
 *   - `sed -i tests/x.test.ts`
 * This check parses the Bash command heuristically and blocks the same set
 * of test_file paths.
 *
 * The parser is intentionally conservative (false-negatives over false-
 * positives). Layered defense: Edit/Write hook + Bash hook + a green-phase
 * cycle-tests-pass.sh re-run after each candidate apply.
 */
function checkBashFileWriteDuringGreen(toolInput, forgeRoot) {
  if (!toolInput) return null;
  const command = String(toolInput.command || "");
  if (!command) return null;

  const root = resolveForgeRoot(forgeRoot);
  if (!root) return null;

  const state = readState(root);
  if (!state || state.phase !== "green") return null;

  const cycleId = state.current_cycle ?? state.currentCycle ?? 1;
  const cycleDir = resolve(root, "cycles", String(cycleId));
  const tests = loadTestsJson(cycleDir);
  if (tests.length === 0) return null;

  const testFiles = new Set(tests.map((t) => t.test_file).filter(Boolean));
  if (testFiles.size === 0) return null;

  const writeTargets = extractBashWriteTargets(command);
  if (writeTargets.length === 0) return null;

  const repoRoot = resolve(root, "..");
  for (const target of writeTargets) {
    const abs = target.startsWith("/") ? target : resolve(repoRoot, target);
    const rel = makeRepoRelative(abs, repoRoot);
    const residue = peelCandidatePrefix(rel);
    const matched = testFiles.has(rel)
      ? rel
      : residue && testFiles.has(residue)
      ? residue
      : null;
    if (matched) {
      return [
        "[BLOCK] Forge Guard: Bash file-write to test-file path during green",
        "",
        `Cycle ${cycleId} is in 'green' phase. Bash commands cannot write to`,
        `paths listed in tests.json — same anti-weakening rule, closing the`,
        `shell side door (redirects, cp/mv, sed -i).`,
        "",
        `Blocked target:    ${target}`,
        `Resolved test_file: ${matched}`,
        "",
        "If the test is genuinely wrong, escalate to the cycle's /goal driver;",
        "do not patch tests during green.",
      ].join("\n");
    }
  }
  return null;
}

// Heuristic: extract paths the command would write to.
// Patterns covered:
//   - `> path` and `>> path` redirects (single command; ignores quoted strings)
//   - `| tee path` and `| tee -a path`
//   - `cp src dst` and `mv src dst` (last positional arg = destination;
//     multi-arg `-t` form is missed — known limitation)
//   - `sed -i path` and `sed -i.bak path`
function extractBashWriteTargets(command) {
  const targets = [];
  const stripQuotes = (s) => s.replace(/^["']|["']$/g, "");

  for (const m of command.matchAll(
    /(?:^|[^&|>])(?:>>?|\|\s*tee\s+(?:-a\s+)?)\s*([^\s;&|<>]+)/g
  )) {
    targets.push(stripQuotes(m[1]));
  }
  for (const m of command.matchAll(
    /\b(?:cp|mv)\s+(?:-[a-zA-Z]+\s+)*[^\s;&|<>]+\s+([^\s;&|<>]+)/g
  )) {
    targets.push(stripQuotes(m[1]));
  }
  for (const m of command.matchAll(
    /\bsed\s+(?:-[a-zA-Z]+\s+)*-i(?:\.\w+)?\s+(?:-[a-zA-Z]+\s+)*(?:'[^']*'|"[^"]*"|[^\s;&|<>]+)\s+([^\s;&|<>]+)/g
  )) {
    targets.push(stripQuotes(m[1]));
  }
  return targets;
}

// --- Main ----------------------------------------------------------------

async function main() {
  const hookType = process.argv[2]; // "pre-tool-use"
  if (hookType !== "pre-tool-use") {
    process.exit(0);
  }

  const input = parseStdin();
  if (!input) process.exit(0);

  const toolName = input.tool_name || "";
  const toolInput = input.tool_input || {};
  const filePath = toolInput.file_path;
  const forgeRoot = filePath ? findForgeRoot(filePath) : null;

  const violations = [];

  if (toolName === "Edit" || toolName === "Write") {
    violations.push(checkTestFileEditDuringGreen(filePath, forgeRoot));
  }
  if (toolName === "Bash") {
    violations.push(checkBashFileWriteDuringGreen(toolInput, forgeRoot));
  }

  const real = violations.filter(Boolean);
  if (real.length > 0) {
    process.stderr.write(real.join("\n\n---\n\n") + "\n");
    process.exit(2);
  }
  process.exit(0);
}

main().catch(() => process.exit(0));

// Exported for unit-level fixture coverage (not used at runtime).
export {
  checkTestFileEditDuringGreen,
  checkBashFileWriteDuringGreen,
  extractBashWriteTargets,
  peelCandidatePrefix,
  makeRepoRelative,
  isForgeArtifact,
};
