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

# Set up logging — query debug config from nvim
log_post() { :; }
if [[ -n "${NVIM_SOCKET:-}" ]]; then
  _POST_CTX=$(nvim --server "$NVIM_SOCKET" --remote-expr "luaeval(\"vim.json.encode({debug=require('code-preview.log').is_enabled(),log_file=require('code-preview.log').get_log_path() or ''})\")" 2>/dev/null || echo '{}')
  _POST_DEBUG=$(echo "$_POST_CTX" | jq -r '.debug // false')
  _POST_LOG_FILE=$(echo "$_POST_CTX" | jq -r '.log_file // ""')
  if [[ "$_POST_DEBUG" == "true" && -n "$_POST_LOG_FILE" ]]; then
    log_post() { printf '[%s] [INFO] core-post-tool.sh: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$_POST_LOG_FILE"; }
  fi
fi

log_post "tool=$TOOL_NAME"

# For Bash tool (rm detection), only clear deletion markers — don't touch edit markers or diff tab
if [[ "$TOOL_NAME" == "Bash" ]]; then
  nvim_send "require('code-preview.changes').clear_by_status('deleted')" || true
  nvim_send "vim.defer_fn(function() pcall(function() require('code-preview.neo_tree').refresh() end) end, 200)" || true
  exit 0
fi

# ApplyPatch: extract file paths from patch_text and close each diff
if [[ "$TOOL_NAME" == "ApplyPatch" ]]; then
  PATCH_TEXT="$(echo "$INPUT" | jq -r '.tool_input.patch_text // empty' 2>/dev/null || true)"
  CWD_POST="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
  if [[ -n "$PATCH_TEXT" ]]; then
    # Extract paths from both standard unified diff (+++ lines) and
    # custom patch format (*** Update File: / *** Add File: lines)
    extract_patch_paths() {
      echo "$1" | grep -E '^\+\+\+ ' | while IFS= read -r line; do
        fpath="${line#+++ }"
        fpath="${fpath#b/}"
        [[ "$fpath" == "/dev/null" ]] && continue
        echo "$fpath"
      done
      echo "$1" | grep -E '^\*\*\* (Update|Add) File:' | while IFS= read -r line; do
        echo "$line" | sed -E 's/^\*\*\* (Update|Add) File:[[:space:]]*//' | sed 's/[[:space:]]*$//'
      done
    }

    while IFS= read -r fpath; do
      [[ -z "$fpath" ]] && continue
      if [[ "$fpath" != /* && -n "$CWD_POST" ]]; then
        fpath="$CWD_POST/$fpath"
      fi
      fpath_esc="$(escape_lua "$fpath")"
      log_post "closing diff for patch file=$fpath"
      nvim_send "require('code-preview.diff').close_for_file('$fpath_esc')" || true
    done < <(extract_patch_paths "$PATCH_TEXT")
  fi
  rm -f "${TMPDIR:-/tmp}"/claude-diff-original* "${TMPDIR:-/tmp}"/claude-diff-proposed* "${TMPDIR:-/tmp}"/claude-patch-*
  exit 0
fi

# Extract file path early — needed for tagged is_open() check
FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
FILE_PATH_ESC="$(escape_lua "${FILE_PATH:-}")"

# Tell Lua to handle this file's close — tolerates out-of-order post-hooks
# (OpenCode may fire them in a different order than pre-hooks).
if [[ -n "$FILE_PATH" ]]; then
  log_post "closing diff for file=$FILE_PATH"
  nvim_send "require('code-preview.diff').close_for_file('$FILE_PATH_ESC')" || true
  # neo_tree.refresh() is handled inside close_for_file() via vim.schedule()
fi

# Clean up temp files (both legacy shared paths and per-PID paths)
rm -f "${TMPDIR:-/tmp}"/claude-diff-original* "${TMPDIR:-/tmp}"/claude-diff-proposed*

exit 0
