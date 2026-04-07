#!/usr/bin/env bash
# claude-close-diff.sh — PostToolUse hook for Claude Code
# Closes the diff preview tab in Neovim after the user accepts or rejects.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read stdin and extract cwd for socket discovery
INPUT="$(cat)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
TRANSCRIPT_PATH="$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
TOOL_USE_ID="$(echo "$INPUT" | jq -r '.tool_use_id // empty' 2>/dev/null || true)"

# Discover Neovim socket (prefer instance whose cwd matches project) and load RPC helpers
source "$SCRIPT_DIR/nvim-socket.sh" "$CWD" 2>/dev/null
source "$SCRIPT_DIR/nvim-send.sh"
source "$SCRIPT_DIR/claude-preview-transcript-watch.sh"

# For Bash tool (rm detection), only clear deletion markers — don't touch edit markers or diff tab
if [[ "$TOOL_NAME" == "Bash" ]]; then
  nvim_send "require('claude-preview.changes').clear_by_status('deleted')" || true
  nvim_send "vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').refresh() end) end, 200)" || true
  exit 0
fi

# Only clean up if a diff was actually open
DIFF_OPEN=$(nvim --server "$NVIM_SOCKET" --remote-expr "luaeval(\"require('claude-preview.diff').is_open()\")" 2>/dev/null || echo "false")

if [[ "$DIFF_OPEN" == "true" ]]; then
  FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
  nvim_send "require('claude-preview.changes').clear_all()" || true
  nvim_send "require('claude-preview.diff').close_diff()" || true
  if [[ -n "$FILE_PATH" ]]; then
    FILE_PATH_ESC="$(escape_lua "$FILE_PATH")"
    nvim_send "vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').refresh() end) vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').reveal('$FILE_PATH_ESC') end) end, 200) end, 200)" || true
  else
    nvim_send "vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').refresh() end) end, 200)" || true
  fi
fi

# Clean up temp files
rm -f "${TMPDIR:-/tmp}/claude-diff-original" "${TMPDIR:-/tmp}/claude-diff-proposed"

# Stop the transcript watcher (if one was spawned by PreToolUse)
if [[ -n "$TRANSCRIPT_PATH" && -n "$TOOL_USE_ID" ]]; then
  claude_preview_stop_transcript_watcher "$TRANSCRIPT_PATH" "$TOOL_USE_ID" || true
fi

exit 0
