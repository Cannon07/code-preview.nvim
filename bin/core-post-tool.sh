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
#   CODE_PREVIEW_BACKEND  — "claudecode" or "opencode" (currently unused, reserved)

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
  nvim_send "require('code-preview.changes').clear_by_status('deleted')" || true
  nvim_send "vim.defer_fn(function() pcall(function() require('code-preview.neo_tree').refresh() end) end, 200)" || true
  exit 0
fi

# Extract file path early — needed for tagged is_open() check
FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
FILE_PATH_ESC="$(escape_lua "${FILE_PATH:-}")"

# Tell Lua to handle this file's close — tolerates out-of-order post-hooks
# (OpenCode may fire them in a different order than pre-hooks).
if [[ -n "$FILE_PATH" ]]; then
  nvim_send "require('code-preview.diff').close_for_file('$FILE_PATH_ESC')" || true
  # neo_tree.refresh() is handled inside close_for_file() via vim.schedule()
fi

# Clean up temp files (both legacy shared paths and per-PID paths)
rm -f "${TMPDIR:-/tmp}"/claude-diff-original* "${TMPDIR:-/tmp}"/claude-diff-proposed*

exit 0
