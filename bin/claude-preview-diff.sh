#!/usr/bin/env bash
# claude-preview-diff.sh — PreToolUse hook for Claude Code
# Intercepts Edit/Write/MultiEdit, computes proposed file content,
# and sends a diff preview to Neovim via RPC before the user accepts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read the full hook JSON from stdin
INPUT="$(cat)"

TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name')"
CWD="$(echo "$INPUT" | jq -r '.cwd')"

# Discover Neovim socket (prefer instance whose cwd matches project) and load RPC helpers
source "$SCRIPT_DIR/nvim-socket.sh" "$CWD" 2>/dev/null || true
source "$SCRIPT_DIR/nvim-send.sh"

HAS_NVIM=true
if [[ -z "${NVIM_SOCKET:-}" ]]; then
  HAS_NVIM=false
fi

TMPDIR="${TMPDIR:-/tmp}"
ORIG_FILE="$TMPDIR/claude-diff-original"
PROP_FILE="$TMPDIR/claude-diff-proposed"

# --- Compute original and proposed file content ---

case "$TOOL_NAME" in
  Edit)
    FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path')"
    OLD_STRING="$(echo "$INPUT" | jq -r '.tool_input.old_string')"
    NEW_STRING="$(echo "$INPUT" | jq -r '.tool_input.new_string')"
    REPLACE_ALL="$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')"

    if [[ -f "$FILE_PATH" ]]; then
      cp "$FILE_PATH" "$ORIG_FILE"
    else
      > "$ORIG_FILE"
    fi

    nvim --headless -l "$SCRIPT_DIR/apply-edit.lua" "$FILE_PATH" "$OLD_STRING" "$NEW_STRING" "$REPLACE_ALL" "$PROP_FILE"
    ;;

  Write)
    FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path')"
    CONTENT="$(echo "$INPUT" | jq -r '.tool_input.content')"

    if [[ -f "$FILE_PATH" ]]; then
      cp "$FILE_PATH" "$ORIG_FILE"
    else
      > "$ORIG_FILE"
    fi

    printf '%s' "$CONTENT" > "$PROP_FILE"
    ;;

  MultiEdit)
    FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path')"

    if [[ -f "$FILE_PATH" ]]; then
      cp "$FILE_PATH" "$ORIG_FILE"
    else
      > "$ORIG_FILE"
    fi

    nvim --headless -l "$SCRIPT_DIR/apply-multi-edit.lua" "$INPUT" "$PROP_FILE"
    ;;

  *)
    exit 0
    ;;
esac

# --- Send diff to Neovim ---

DISPLAY_NAME="${FILE_PATH#"$CWD/"}"

if [[ "$HAS_NVIM" == "true" ]]; then
  ORIG_ESC="$(escape_lua "$ORIG_FILE")"
  PROP_ESC="$(escape_lua "$PROP_FILE")"
  DISPLAY_ESC="$(escape_lua "$DISPLAY_NAME")"
  FILE_PATH_ESC="$(escape_lua "$FILE_PATH")"

  # Determine change status for neo-tree indicator
  # Check if the actual file exists on disk (not the temp copy, which is always created)
  if [[ -f "$FILE_PATH" ]]; then
    CHANGE_STATUS="modified"
  else
    CHANGE_STATUS="created"
  fi

  nvim_send "require('claude-preview.changes').set('$FILE_PATH_ESC', '$CHANGE_STATUS')"
  nvim_send "pcall(function() require('claude-preview.neo_tree').refresh() end)"
  # Reveal the file in neo-tree: for modified files reveal the file itself,
  # for created files reveal the nearest existing parent directory
  if [[ "$CHANGE_STATUS" == "modified" ]]; then
    nvim_send "vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').reveal('$FILE_PATH_ESC') end) end, 300)"
  else
    # Walk up to find the nearest existing parent directory
    REVEAL_DIR="$(dirname "$FILE_PATH")"
    while [[ ! -d "$REVEAL_DIR" && "$REVEAL_DIR" != "/" ]]; do
      REVEAL_DIR="$(dirname "$REVEAL_DIR")"
    done
    # Reveal a file inside the parent dir to force neo-tree to expand it
    REVEAL_TARGET="$(find "$REVEAL_DIR" -maxdepth 1 -type f | head -1)"
    if [[ -z "$REVEAL_TARGET" ]]; then
      REVEAL_TARGET="$REVEAL_DIR"
    fi
    REVEAL_TARGET_ESC="$(escape_lua "$REVEAL_TARGET")"
    nvim_send "vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').reveal('$REVEAL_TARGET_ESC') end) end, 300)"
  fi
  nvim_send "require('claude-preview.diff').show_diff('$ORIG_ESC', '$PROP_ESC', '$DISPLAY_ESC')"
fi

# --- Always ask for user confirmation ---

if [[ "$HAS_NVIM" == "true" ]]; then
  REASON="Diff preview sent to Neovim. Review before accepting."
else
  REASON="Neovim not running. Review the diff in CLI before accepting."
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$REASON"
