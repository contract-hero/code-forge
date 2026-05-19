#!/usr/bin/env node

/**
 * Forge Guard (Option D): block writes that would weaken tests during green.
 *
 * See agents/test-author.md for tests.json schema and
 * docs/goal-integration.md for protocol context.
 */

import { readFileSync, existsSync, realpathSync } from "node:fs";
import { resolve, dirname, basename } from "node:path";

// --- Helpers --------------------------------------------------------------

/**
 * Parse a JSON payload off stdin. Distinguishes three cases:
 *   - empty stdin → returns { kind: "empty" } (legitimate no-op)
 *   - malformed   → returns { kind: "malformed", error: <string> } (fail-closed signal)
 *   - parsed      → returns { kind: "parsed", value: <object> }
 */
function parseStdin() {
  let raw;
  try {
    raw = readFileSync(0, "utf8");
  } catch (err) {
    return { kind: "malformed", error: `stdin read failed: ${err.message}` };
  }
  if (!raw.trim()) return { kind: "empty" };
  try {
    return { kind: "parsed", value: JSON.parse(raw) };
  } catch (err) {
    return { kind: "malformed", error: `stdin JSON parse failed: ${err.message}` };
  }
}

/**
 * Read .forge/state.json. Returns { kind: "missing" | "malformed" | "parsed", value? }.
 * Malformed is a *signal*, not a silent null — the caller decides how to react.
 */
function readState(forgeRoot) {
  if (!forgeRoot) return { kind: "missing" };
  const stateJson = resolve(forgeRoot, "state.json");
  if (!existsSync(stateJson)) return { kind: "missing" };
  try {
    return { kind: "parsed", value: JSON.parse(readFileSync(stateJson, "utf8")) };
  } catch (err) {
    return { kind: "malformed", error: `state.json parse failed: ${err.message}` };
  }
}

function findForgeRoot(filePath) {
  // Non-greedy: prefer the OUTERMOST .forge segment. A staged candidate path
  // like `<repo>/.forge/cycles/C1/green/candidates/worker-3/files/.forge/state.json`
  // has two `.forge/` segments — the outer one is the real forge root; the
  // inner one is part of a worker's candidate-staged tree.
  const match = filePath?.match(/^(.+?\/\.forge)\//);
  if (match) return match[1];
  if (filePath?.endsWith("/.forge")) return filePath;
  return null;
}

// Realpath the longest-existing-ancestor prefix of `p`, then re-attach the
// missing trailing segments. Lets us canonicalize a path that names a planned
// write whose intermediate dirs may also not exist.
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

// Strip the absolute repoRoot prefix. Both sides go through realpathLongestPrefix
// so /var → /private/var symlink crossings don't defeat the string compare.
function makeRepoRelative(filePath, repoRoot) {
  const realRoot = realpathLongestPrefix(repoRoot);
  const realFile = realpathLongestPrefix(filePath);
  return realFile.startsWith(realRoot + "/")
    ? realFile.slice(realRoot.length + 1)
    : realFile;
}

// Workers stage candidates under
// .forge/cycles/<id>/green/candidates/worker-K/files/<repo-relative-path>.
// Cycle IDs can be either strings (C1, C2) or numbers (1, 2).
const CANDIDATE_STAGING_RE =
  /^\.forge\/cycles\/[^/]+\/green\/candidates\/worker-\d+\/files\/(.+)$/;

function peelCandidatePrefix(relPath) {
  const m = relPath.match(CANDIDATE_STAGING_RE);
  return m ? m[1] : null;
}

function loadTestsJson(cycleDir) {
  const testsPath = resolve(cycleDir, "tests.json");
  if (!existsSync(testsPath)) return { kind: "missing" };
  try {
    return { kind: "parsed", value: JSON.parse(readFileSync(testsPath, "utf8")) };
  } catch (err) {
    return { kind: "malformed", error: `tests.json parse failed: ${err.message}` };
  }
}

function resolveForgeRoot(forgeRoot) {
  if (forgeRoot) return forgeRoot;
  const candidate = resolve(process.cwd(), ".forge");
  return existsSync(candidate) ? candidate : null;
}

// Recognize the load-bearing rule-5 anchor files: state.json (because it
// carries `phase`) and any cycle's tests.json (because it carries the list
// of test_file paths). Block direct edits to these during green, since
// rewriting them disarms the rule.
const STATE_JSON_TAIL_RE = /(?:^|\/)\.forge\/state\.json$/;
const TESTS_JSON_TAIL_RE = /(?:^|\/)\.forge\/cycles\/[^/]+\/tests\.json$/;

function isProtectedAnchor(relPath) {
  return STATE_JSON_TAIL_RE.test(relPath) || TESTS_JSON_TAIL_RE.test(relPath);
}

// --- The rule -----------------------------------------------------------

/**
 * Edit/Write block. Blocks when:
 *   - phase == "green" AND
 *     - file is a test_file listed in this cycle's tests.json, OR
 *     - file is a protected anchor (state.json / tests.json itself)
 *
 * Returns:
 *   - null when no violation
 *   - { error: <stderr message>, exitCode: 2 } when a violation is detected
 *   - { error: <stderr message>, exitCode: 2 } when state/tests JSON is malformed
 *     (fail-closed: a corrupted anchor file cannot silently disengage the rule)
 */
function checkTestFileEditDuringGreen(filePath, forgeRoot) {
  if (!filePath) return null;
  const root = resolveForgeRoot(forgeRoot ?? findForgeRoot(filePath));
  if (!root) return null;

  const state = readState(root);
  if (state.kind === "missing") return null;
  if (state.kind === "malformed") {
    return {
      exitCode: 2,
      error: [
        "[BLOCK] Forge Guard: .forge/state.json is malformed",
        "",
        state.error,
        "",
        "Refusing to evaluate the green-phase rule against an unparseable",
        "state file. Fix or remove .forge/state.json and retry.",
      ].join("\n"),
    };
  }

  if (state.value.phase !== "green") return null;

  const repoRoot = resolve(root, "..");
  const relPath = makeRepoRelative(filePath, repoRoot);
  const candidateResidue = peelCandidatePrefix(relPath);
  const peeled = candidateResidue ?? relPath;

  // Protect the anchor files themselves. tests.json and state.json are not
  // listed inside tests.json[*].test_file, so the test-list lookup below
  // would miss them — but rewriting either disarms the rule.
  if (isProtectedAnchor(relPath) || isProtectedAnchor(peeled)) {
    return {
      exitCode: 2,
      error: [
        "[BLOCK] Forge Guard: anchor-file edit blocked during green phase",
        "",
        `Cycle ${state.value.current_cycle ?? "?"} is in 'green'. Edits to`,
        `state.json or any cycle's tests.json are blocked during green —`,
        `rewriting either would disarm the test-immutability rule.`,
        "",
        `Blocked path: ${relPath}`,
        "",
        "If tests need amending, the cycle must roll back to the test-list",
        "step and the test-author re-emit tests.json. Don't edit anchors in green.",
      ].join("\n"),
    };
  }

  const cycleId = state.value.current_cycle ?? state.value.currentCycle ?? 1;
  const cycleDir = resolve(root, "cycles", String(cycleId));
  const tests = loadTestsJson(cycleDir);
  if (tests.kind === "missing") return null;
  if (tests.kind === "malformed") {
    return {
      exitCode: 2,
      error: [
        "[BLOCK] Forge Guard: tests.json malformed for current cycle",
        "",
        tests.error,
        "",
        "Refusing to evaluate the green-phase rule against an unparseable",
        `tests.json (cycles/${cycleId}/tests.json). Fix or re-emit.`,
      ].join("\n"),
    };
  }

  if (tests.value.length === 0) return null;
  const testFiles = new Set(tests.value.map((t) => t.test_file).filter(Boolean));
  const directHit = testFiles.has(relPath);
  const candidateHit = candidateResidue && testFiles.has(candidateResidue);
  if (!directHit && !candidateHit) return null;

  return {
    exitCode: 2,
    error: [
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
    ].join("\n"),
  };
}

/**
 * Bash side-door block. Blocks Bash commands during green that:
 *   - write to a test_file path via any of the recognized patterns, OR
 *   - mention a test_file path while invoking a shell escape (sh -c, bash -c,
 *     eval, xargs sh, env … sh -c) — these defeat purely-syntactic matching
 *     and we'd rather false-positive than allow the bypass class.
 *
 * Pattern coverage (vs the Sonnet implementer's likely fallbacks):
 *   - Redirects: > >> &> >| 2> [0-9]> with optional 'tee [-a]' pipe
 *   - cp / mv (last-arg destination, plus `-t <dir>` flag form)
 *   - sed -i (GNU `-i'.bak'` and BSD `-i ''` empty-arg forms)
 *   - perl -i / perl -pi / perl -i.bak
 *   - awk -i inplace
 *   - ruby -i
 *   - python -c "open('path','w'|'a'|'x').write(…)"
 *   - dd of=<path>
 *   - truncate <path> / truncate -s … <path>
 *   - install <src> <dst>
 *   - ln -s / ln -sf <target> <linkname>
 *   - rm / rm -f / rm -rf (when targeting a tracked test_file)
 *
 * Layered with a CI-time `git diff tests/` check this is closer to defense
 * in depth; alone, it's a moving target. We accept false-positives over
 * false-negatives here.
 */
function checkBashFileWriteDuringGreen(toolInput, forgeRoot) {
  if (!toolInput) return null;
  const command = String(toolInput.command || "");
  if (!command) return null;

  const root = resolveForgeRoot(forgeRoot);
  if (!root) return null;

  const state = readState(root);
  if (state.kind === "missing") return null;
  if (state.kind === "malformed") {
    return {
      exitCode: 2,
      error: [
        "[BLOCK] Forge Guard: .forge/state.json malformed; refusing Bash check",
        "",
        state.error,
      ].join("\n"),
    };
  }

  if (state.value.phase !== "green") return null;

  const cycleId = state.value.current_cycle ?? state.value.currentCycle ?? 1;
  const cycleDir = resolve(root, "cycles", String(cycleId));
  const tests = loadTestsJson(cycleDir);
  if (tests.kind === "missing") return null;
  if (tests.kind === "malformed") {
    return {
      exitCode: 2,
      error: [
        "[BLOCK] Forge Guard: tests.json malformed; refusing Bash check",
        "",
        tests.error,
      ].join("\n"),
    };
  }

  const testFiles = new Set(tests.value.map((t) => t.test_file).filter(Boolean));
  const repoRoot = resolve(root, "..");

  // 1. Mention-based block for shell-escape invocations. Two flavors:
  //    - eval / `<shell> -c …` / heredoc payloads: don't try to parse the
  //      inner command, just check whether any test_file path is mentioned.
  //    - in-place editors (perl/ruby/awk -i): regex-based extraction is
  //      fragile across flag orderings, so we fall back to a mention check.
  //    False-positive over false-negative.
  const shellEscapeRe =
    /\b(?:sh|bash|zsh|ksh|dash|xargs|env|nohup|unbuffer)\b[^|;&\n]*?(?:-c\b|<<<|<<-?\s*\w)/;
  const evalRe = /\beval\b/;
  // Flag-like `-i` does not have a word boundary before the dash (space + `-`
  // is non-word + non-word), so anchor explicitly on a leading whitespace.
  // Allow `-i`, `-pi`, `-i.bak`, `-inplace`.
  const inplaceEditorRe = /\b(?:perl|ruby|awk)\b[^|;&\n]*?\s-p?i(?:np(?:lace)?)?(?:\.\w+)?\b/;
  if (shellEscapeRe.test(command) || evalRe.test(command) || inplaceEditorRe.test(command)) {
    for (const tf of testFiles) {
      if (command.includes(tf)) {
        return blockBashViolation({
          cycleId,
          target: tf,
          matched: tf,
          reason: "shell-escape / in-place editor invocation references a test_file path",
        });
      }
    }
    // Anchor paths (state.json / cycles/<id>/tests.json) — same scrutiny.
    const anchorMentions = [".forge/state.json", `cycles/${cycleId}/tests.json`];
    for (const tf of anchorMentions) {
      if (command.includes(tf)) {
        return blockBashViolation({
          cycleId,
          target: tf,
          matched: tf,
          reason: "shell-escape / in-place editor invocation references a forge-guard anchor",
        });
      }
    }
  }

  // 2. Pattern-based write-target extraction.
  const writeTargets = extractBashWriteTargets(command);
  for (const target of writeTargets) {
    const abs = target.startsWith("/") ? target : resolve(repoRoot, target);
    const rel = makeRepoRelative(abs, repoRoot);
    const residue = peelCandidatePrefix(rel);
    const peeled = residue ?? rel;

    // Anchor-file writes (state.json / current cycle's tests.json) are
    // blocked unconditionally during green — rewriting them disarms the rule.
    if (isProtectedAnchor(rel) || isProtectedAnchor(peeled)) {
      return blockBashViolation({
        cycleId,
        target,
        matched: rel,
        reason: "Bash write to a forge-guard anchor file (state.json / tests.json)",
      });
    }

    const matched = testFiles.has(rel)
      ? rel
      : residue && testFiles.has(residue)
      ? residue
      : null;
    if (matched) {
      return blockBashViolation({
        cycleId,
        target,
        matched,
        reason: "Bash file-write to a test_file path",
      });
    }
  }
  return null;
}

function blockBashViolation({ cycleId, target, matched, reason }) {
  return {
    exitCode: 2,
    error: [
      "[BLOCK] Forge Guard: Bash test-file mutation blocked during green",
      "",
      `Cycle ${cycleId} is in 'green' phase. ${reason}.`,
      "",
      `Blocked target:    ${target}`,
      `Resolved test_file: ${matched}`,
      "",
      "If the test is genuinely wrong, escalate to the cycle's /goal driver;",
      "do not patch tests during green.",
    ].join("\n"),
  };
}

/**
 * Heuristic extractor: collect paths the command would write to.
 * Strategy: strip quoted substrings first (so redirects inside quoted args
 * don't trip the matcher), then scan for each known write family.
 */
function extractBashWriteTargets(command) {
  // Drop quoted substrings so `echo "x > tests/foo"` doesn't look like a
  // redirect. Conservative: removes both single- and double-quoted content.
  const stripped = command
    .replace(/"[^"]*"/g, '""')
    .replace(/'[^']*'/g, "''");
  const targets = [];
  const stripQuotes = (s) => s.replace(/^["']+|["']+$/g, "");
  const push = (raw) => {
    if (!raw) return;
    targets.push(stripQuotes(raw));
  };

  // Redirects: support `>`, `>>`, `&>`, `&>>`, `>|`, `2>`, `[0-9]+>`,
  // `[0-9]+>>`, plus `| tee [-a]`. Match the operator near end of a
  // command-segment boundary.
  const redirectRe =
    /(?:^|[\s;&|()])(?:&?>>?\|?|[0-9]+&?>>?\|?|\|\s*tee\s+(?:-a\s+)?)\s*([^\s;&|<>()]+)/g;
  for (const m of stripped.matchAll(redirectRe)) push(m[1]);

  // cp / mv with last-positional destination.
  const cpMvRe = /\b(?:cp|mv|install)\s+(?:-[a-zA-Z]+\s+)*[^\s;&|<>()]+\s+([^\s;&|<>()]+)/g;
  for (const m of stripped.matchAll(cpMvRe)) push(m[1]);

  // cp / mv / install with `-t <dest-dir> <src…>` form. The destination is
  // the arg immediately after -t, and every src that follows can land
  // inside it — but here we only care whether a test_file path appears as
  // any positional. So harvest every token after -t.
  const tFormRe = /\b(?:cp|mv|install)\s+(?:-[a-zA-Z]*\s+)*-t\s+([^\s;&|<>()]+)((?:\s+[^\s;&|<>()]+)+)/g;
  for (const m of stripped.matchAll(tFormRe)) {
    push(m[1]);
    for (const tok of m[2].trim().split(/\s+/)) push(tok);
  }

  // sed -i, GNU and BSD forms.
  //   GNU:  sed -i 's/x/y/' path        sed -i.bak 's/x/y/' path
  //   BSD:  sed -i '' 's/x/y/' path
  // After quote-stripping above, BSD `sed -i '' 's/x/y/' tests/foo.test.ts`
  // becomes `sed -i '' '' tests/foo.test.ts`. The optional `(?:''\s+|""\s+)?`
  // consumes the BSD empty-backup-arg before the script slot.
  const sedRe = /\bsed\s+(?:-[a-zA-Z]+\s+)*-i(?:\.\w+)?\s+(?:''\s+|""\s+)?(?:''|""|\S+)\s+([^\s;&|<>()]+)/g;
  for (const m of stripped.matchAll(sedRe)) push(m[1]);

  // perl -i / perl -pi / perl -i.bak: last positional is the file.
  const perlInplaceRe =
    /\bperl\s+(?:-[a-zA-Z]+\s+)*(?:-pi?|-i)(?:\.\w+)?(?:\s+-[a-zA-Z]+)*\s+(?:-e\s+\S+\s+)?([^\s;&|<>()]+)/g;
  for (const m of stripped.matchAll(perlInplaceRe)) push(m[1]);

  // awk -i inplace 'script' file...
  const awkInplaceRe = /\bawk\s+-i\s+inplace\b[^\n]*?(?:'[^']*'|"[^"]*"|\S+)\s+([^\s;&|<>()]+)/g;
  for (const m of stripped.matchAll(awkInplaceRe)) push(m[1]);

  // ruby -i
  const rubyInplaceRe = /\bruby\s+(?:-[a-zA-Z]+\s+)*-i(?:\.\w+)?[^\n]*?(?:-e\s+\S+\s+)?([^\s;&|<>()]+)/g;
  for (const m of stripped.matchAll(rubyInplaceRe)) push(m[1]);

  // python -c "open('path','w'|'a'|'x').write(...)"
  // We already stripped quotes; the inner path becomes an empty string.
  // Fall back to a raw-command scan for the open() form.
  const pyOpenRe = /\bpython3?\s+-c\s+(?:""|'')\s*$/m;
  if (pyOpenRe.test(stripped)) {
    const rawOpen = command.matchAll(
      /\bopen\(\s*(?:'([^']+)'|"([^"]+)")\s*,\s*['"][wax][bt+]?['"]/g
    );
    for (const m of rawOpen) push(m[1] || m[2]);
  }

  // dd of=path
  const ddRe = /\bdd\s+[^\n]*?of=([^\s;&|<>()]+)/g;
  for (const m of stripped.matchAll(ddRe)) push(m[1]);

  // truncate <path>  /  truncate -s SIZE <path>
  const truncateRe = /\btruncate\s+(?:-[a-zA-Z]+\s+\S+\s+)*([^\s;&|<>()]+)/g;
  for (const m of stripped.matchAll(truncateRe)) push(m[1]);

  // ln -s / ln -sf <target> <linkname>: the link name is the destination.
  const lnRe = /\bln\s+(?:-[a-zA-Z]+\s+)*[^\s;&|<>()]+\s+([^\s;&|<>()]+)/g;
  for (const m of stripped.matchAll(lnRe)) push(m[1]);

  // rm targeting a tracked path is functionally equivalent to truncation for
  // anti-weakening; collect every positional argument after `rm`.
  const rmRe = /\brm\s+(?:-[a-zA-Z]+\s+)*((?:[^\s;&|<>()]+\s*)+)/g;
  for (const m of stripped.matchAll(rmRe)) {
    for (const tok of m[1].trim().split(/\s+/)) push(tok);
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
  if (input.kind === "empty") process.exit(0);
  if (input.kind === "malformed") {
    process.stderr.write(
      `[BLOCK] Forge Guard: malformed PreToolUse payload — ${input.error}\n` +
        "Refusing tool call rather than fail-open.\n"
    );
    process.exit(2);
  }

  const payload = input.value;
  const toolName = payload.tool_name || "";
  const toolInput = payload.tool_input || {};
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
    // Highest exitCode wins; messages joined.
    const exitCode = Math.max(...real.map((v) => v.exitCode));
    process.stderr.write(real.map((v) => v.error).join("\n\n---\n\n") + "\n");
    process.exit(exitCode);
  }
  process.exit(0);
}

// Fail closed on any unexpected throw — silent exit-0 would let a test
// mutation through during green, which is the precise failure mode the
// guard exists to prevent.
main().catch((err) => {
  process.stderr.write(
    `[BLOCK] Forge Guard: internal error — ${err && err.stack ? err.stack : err}\n` +
      "Refusing tool call rather than fail-open. Investigate and re-run.\n"
  );
  process.exit(2);
});
