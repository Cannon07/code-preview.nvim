#!/usr/bin/env bash
# claude-user-prompt-cleanup.sh — UserPromptSubmit hook for Claude Code
# Belt-and-suspenders fallback: closes any orphaned diff preview tab
# when the user sends their next message. Catches anything the
# transcript watcher missed (e.g. watcher died, nvim socket changed).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT="$(cat)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"

source "$SCRIPT_DIR/nvim-socket.sh" "$CWD" 2>/dev/null || true
source "$SCRIPT_DIR/nvim-send.sh"

if [[ -z "${NVIM_SOCKET:-}" ]]; then
  exit 0
fi

# Fast path: single RPC to check if a diff is open. <100ms when nothing is open.
DIFF_OPEN=$(nvim --server "$NVIM_SOCKET" --remote-expr "luaeval(\"require('claude-preview.diff').is_open() and 1 or 0\")" 2>/dev/null || echo "0")

if [[ "$DIFF_OPEN" == "1" ]]; then
  nvim_send "if require('claude-preview.diff').is_open() then pcall(function() require('claude-preview.changes').clear_all() end) pcall(function() require('claude-preview.diff').close_diff() end) end" || true
  rm -f "${TMPDIR:-/tmp}/claude-diff-original" "${TMPDIR:-/tmp}/claude-diff-proposed"
fi

exit 0
