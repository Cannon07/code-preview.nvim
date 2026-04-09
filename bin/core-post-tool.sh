#!/usr/bin/env bash
# core-post-tool.sh — Unified PostToolUse logic for all backends
#
# Closes the diff preview tab in Neovim after the user accepts or rejects.
#
# Expected JSON format:
#   { "tool_name": "Edit|Write|MultiEdit|Bash|ApplyPatch",
#     "cwd": "/path/to/project",
#     "tool_input": { "file_path": "...", ... } }
#
# Environment:
#   CLAUDE_PREVIEW_BACKEND  — "claude" or "opencode" (currently unused, reserved)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read stdin and extract cwd for socket discovery
INPUT="$(cat)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"

# Discover Neovim socket (prefer instance whose cwd matches project) and load RPC helpers
source "$SCRIPT_DIR/nvim-socket.sh" "$CWD" 2>/dev/null
source "$SCRIPT_DIR/nvim-send.sh"

# For Bash tool (rm detection), only clear deletion markers — don't touch edit markers or diff tab
if [[ "$TOOL_NAME" == "Bash" ]]; then
  nvim_send "require('claude-preview.changes').clear_by_status('deleted')" || true
  nvim_send "vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').refresh() end) end, 200)" || true
  exit 0
fi

# Extract file path early — needed for tagged is_open() check
FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
FILE_PATH_ESC="$(escape_lua "${FILE_PATH:-}")"

# Only clean up if a diff for THIS file is actually open.
# OpenCode fires all before-hooks before any after-hooks, so the open diff
# may belong to a different file — closing it would kill the wrong preview.
DIFF_OPEN=$(nvim --server "$NVIM_SOCKET" --remote-expr "luaeval(\"require('claude-preview.diff').is_open('${FILE_PATH_ESC}')\")" 2>/dev/null || echo "false")

if [[ "$DIFF_OPEN" == "true" ]]; then
  nvim_send "require('claude-preview.changes').clear_all()" || true
  nvim_send "require('claude-preview.diff').close_diff()" || true
  if [[ -n "$FILE_PATH" ]]; then
    nvim_send "vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').refresh() end) vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').reveal('$FILE_PATH_ESC') end) end, 200) end, 200)" || true
  else
    nvim_send "vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').refresh() end) end, 200)" || true
  fi
fi

# Clean up temp files
rm -f "${TMPDIR:-/tmp}/claude-diff-original" "${TMPDIR:-/tmp}/claude-diff-proposed"

exit 0
