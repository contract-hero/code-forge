#!/bin/bash
# deploy.sh — sync this repo's plugin tree to ~/.claude/plugins/code-forge/
#
# Note: The canonical install since v0.1.0 is the dotclaude submodule at
# ~/.claude/code-forge/ (top-level, mirroring sui-pilot). In that workflow
# the submodule itself is the source-of-truth, and this script is
# unnecessary. deploy.sh is kept for legacy non-submodule installs that
# expect the plugin under ~/.claude/plugins/code-forge/.
#
# Usage:
#   bash scripts/deploy.sh           # rsync the plugin tree
#   bash scripts/deploy.sh --dry-run # show what would change
#   bash scripts/deploy.sh --check   # diff dev vs install (exit 0 if in sync)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_ROOT="${HOME}/.claude/plugins/code-forge"

# The set of paths that constitute the plugin (everything else in the repo —
# spec.md, playground.html, docs/, bench/, README.md — is documentation).
PLUGIN_PATHS=(
  ".claude-plugin"
  "agents"
  "commands"
  "hooks"
  "scripts"
  "skills"
  "tests"
  "PLUGIN.md"
)

mode="${1:-}"

if [[ "$mode" == "--check" ]]; then
  diff_count=0
  for p in "${PLUGIN_PATHS[@]}"; do
    if ! diff -r --brief "${REPO_ROOT}/${p}" "${INSTALL_ROOT}/$(basename "${p}")" >/dev/null 2>&1; then
      echo "DRIFT: ${p}"
      diff_count=$((diff_count + 1))
    fi
  done
  if [[ "$diff_count" -eq 0 ]]; then
    echo "in sync"
    exit 0
  else
    echo "${diff_count} path(s) differ between repo and install"
    exit 1
  fi
fi

rsync_flags=(-a --delete)
if [[ "$mode" == "--dry-run" ]]; then
  rsync_flags+=(-n -v)
fi

mkdir -p "${INSTALL_ROOT}"

for p in "${PLUGIN_PATHS[@]}"; do
  if [[ -e "${REPO_ROOT}/${p}" ]]; then
    if [[ -d "${REPO_ROOT}/${p}" ]]; then
      rsync "${rsync_flags[@]}" "${REPO_ROOT}/${p}/" "${INSTALL_ROOT}/$(basename "${p}")/"
    else
      rsync "${rsync_flags[@]}" "${REPO_ROOT}/${p}" "${INSTALL_ROOT}/$(basename "${p}")"
    fi
  fi
done

if [[ "$mode" == "--dry-run" ]]; then
  echo "(dry run; no changes made)"
else
  echo "deployed → ${INSTALL_ROOT}"
fi
