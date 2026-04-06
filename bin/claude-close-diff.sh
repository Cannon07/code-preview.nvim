#!/usr/bin/env bash
# claude-close-diff.sh — PostToolUse hook for Claude Code
# Closes the diff preview tab in Neovim after the user accepts or rejects.

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

# Extract file path for post-close reveal and buffer reload
FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

# Reload nvim buffer Claude edited to display changes without refocus.
# Iterate nvim_list_bufs() with canonical-path comparison instead of vim.fn.bufnr(path),
# which does partial+regex matching on buffer names and mis-matches paths with regex
# metacharacters (e.g. /tmp/foo[1].md).
if [[ -n "$FILE_PATH" ]]; then
  FILE_PATH_ESC="$(escape_lua "$FILE_PATH")"
  nvim_send "local target = vim.uv.fs_realpath('$FILE_PATH_ESC') or vim.fn.fnamemodify('$FILE_PATH_ESC', ':p') for _, b in ipairs(vim.api.nvim_list_bufs()) do local n = vim.api.nvim_buf_get_name(b) if n ~= '' then local name = vim.uv.fs_realpath(n) or vim.fn.fnamemodify(n, ':p') if name == target then vim.api.nvim_buf_call(b, function() vim.cmd('checktime ' .. b) end) break end end end" || true
fi

# Only clean up if a diff was actually open
DIFF_OPEN=$(nvim --server "$NVIM_SOCKET" --remote-expr "luaeval(\"require('claude-preview.diff').is_open()\")" 2>/dev/null || echo "false")

if [[ "$DIFF_OPEN" == "true" ]]; then
  nvim_send "require('claude-preview.changes').clear_all()" || true
  nvim_send "require('claude-preview.diff').close_diff()" || true
  nvim_send "vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').refresh() end) end, 200)" || true
fi

# Clean up temp files
rm -f "${TMPDIR:-/tmp}/claude-diff-original" "${TMPDIR:-/tmp}/claude-diff-proposed"

exit 0
