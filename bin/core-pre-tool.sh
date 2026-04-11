#!/usr/bin/env bash
# core-pre-tool.sh — Unified PreToolUse logic for all backends
#
# Reads a normalized JSON payload from stdin, computes proposed file content,
# and sends a diff preview to Neovim via RPC.
#
# Expected JSON format:
#   { "tool_name": "Edit|Write|MultiEdit|Bash|ApplyPatch",
#     "cwd": "/path/to/project",
#     "tool_input": { "file_path": "...", ... } }
#
# Environment:
#   CODE_PREVIEW_BACKEND  — "claudecode" or "opencode" (gates output format)

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

    NVIM_LISTEN_ADDRESS= nvim --headless -l "$SCRIPT_DIR/apply-edit.lua" "$FILE_PATH" "$OLD_STRING" "$NEW_STRING" "$REPLACE_ALL" "$PROP_FILE"
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

    NVIM_LISTEN_ADDRESS= nvim --headless -l "$SCRIPT_DIR/apply-multi-edit.lua" "$INPUT" "$PROP_FILE"
    ;;

  Bash)
    COMMAND="$(echo "$INPUT" | jq -r '.tool_input.command')"

    # Detect rm commands: split on command separators and check each sub-command
    detect_rm_paths() {
      local cmd="$1"
      # Trim leading whitespace
      cmd="$(echo "$cmd" | sed 's/^[[:space:]]*//')"
      # Match: optional sudo, then rm as standalone command, then flags/paths
      if echo "$cmd" | grep -qE '^(sudo[[:space:]]+)?rm[[:space:]]'; then
        # Strip rm command and known flags, leaving paths
        echo "$cmd" | sed -E 's/^(sudo[[:space:]]+)?rm[[:space:]]+//' \
                     | tr ' ' '\n' \
                     | grep -vE '^-' \
                     | while read -r p; do
                         if [[ -z "$p" ]]; then continue; fi
                         # Resolve relative paths against CWD
                         if [[ "$p" != /* ]]; then
                           echo "$CWD/$p"
                         else
                           echo "$p"
                         fi
                       done
      fi
    }

    # Split command on && || ; and check each part
    RM_PATHS=""
    while IFS= read -r subcmd; do
      while IFS= read -r path; do
        [[ -n "$path" ]] && RM_PATHS="$RM_PATHS $path"
      done < <(detect_rm_paths "$subcmd")
    done < <(echo "$COMMAND" | sed 's/[;&|]\{1,2\}/\n/g')

    RM_PATHS="$(echo "$RM_PATHS" | xargs)"
    if [[ -z "$RM_PATHS" ]]; then
      exit 0  # Not an rm command, pass through
    fi

    # Mark each path as deleted in neo-tree
    if [[ "$HAS_NVIM" == "true" ]]; then
      for path in $RM_PATHS; do
        PATH_ESC="$(escape_lua "$path")"
        nvim_send "require('code-preview.changes').set('$PATH_ESC', 'deleted')" || true
      done
      nvim_send "pcall(function() require('code-preview.neo_tree').refresh() end)" || true
      # Reveal the first deleted file in the tree
      FIRST_PATH="$(echo "$RM_PATHS" | awk '{print $1}')"
      FIRST_ESC="$(escape_lua "$FIRST_PATH")"
      nvim_send "vim.defer_fn(function() pcall(function() require('code-preview.neo_tree').reveal('$FIRST_ESC') end) end, 300)" || true
    fi
    exit 0
    ;;

  ApplyPatch)
    # Stub for V1 — skip diff preview (matches current OpenCode behavior)
    exit 0
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

  # Query config + file visibility from nvim in a single RPC call
  HOOK_CTX=$(nvim --server "$NVIM_SOCKET" --remote-expr "luaeval(\"require('code-preview').hook_context('${FILE_PATH_ESC}')\")" 2>/dev/null || echo '{}')
  # Use explicit conditional: jq's `//` operator treats boolean false like null,
  # which would silently convert `reveal = false` into `true`.
  NEO_TREE_REVEAL=$(echo "$HOOK_CTX" | jq -r 'if .neo_tree_reveal == false then "false" else "true" end')
  NEO_TREE_REVEAL_ROOT=$(echo "$HOOK_CTX" | jq -r '.reveal_root // "cwd"')
  VISIBLE_ONLY=$(echo "$HOOK_CTX" | jq -r '.visible_only // false')
  FILE_VISIBLE=$(echo "$HOOK_CTX" | jq -r '.file_visible // false')
  DEFER_PERMISSIONS=$(echo "$HOOK_CTX" | jq -r 'if .defer_claude_permissions == true then "true" else "false" end')

  # Decide whether to show the diff — skip nvim UI entirely when visible_only
  # is on and the file isn't in any visible window.
  SHOULD_SHOW="1"
  if [[ "$VISIBLE_ONLY" == "true" && "$FILE_VISIBLE" != "true" ]]; then
    SHOULD_SHOW="0"
  fi

  # Determine change status for neo-tree indicator
  if [[ -f "$FILE_PATH" ]]; then
    CHANGE_STATUS="modified"
  else
    CHANGE_STATUS="created"
  fi

  if [[ "$SHOULD_SHOW" == "1" ]]; then
    nvim_send "require('code-preview.changes').set('$FILE_PATH_ESC', '$CHANGE_STATUS')" || true

    # Neo-tree integration (gated by config)
    if [[ "$NEO_TREE_REVEAL" == "true" ]]; then
      # Resolve the directory neo-tree should root from
      REVEAL_DIR=""
      if [[ "$NEO_TREE_REVEAL_ROOT" == "git" ]]; then
        REVEAL_DIR=$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null || echo "")
        REVEAL_DIR="${REVEAL_DIR:-$(dirname "$FILE_PATH")}"
      fi

      # Resolve reveal target. For modified files the path exists; for created
      # files the path (and possibly its parents) don't exist yet, so walk up to
      # the nearest existing directory and reveal a sibling file inside it to
      # force neo-tree to expand the path before virtual nodes are injected.
      if [[ "$CHANGE_STATUS" == "modified" ]]; then
        REVEAL_TARGET="$FILE_PATH"
      else
        REVEAL_PARENT="$(dirname "$FILE_PATH")"
        while [[ ! -d "$REVEAL_PARENT" && "$REVEAL_PARENT" != "/" ]]; do
          REVEAL_PARENT="$(dirname "$REVEAL_PARENT")"
        done
        REVEAL_TARGET="$(find "$REVEAL_PARENT" -maxdepth 1 -type f 2>/dev/null | head -1)"
        REVEAL_TARGET="${REVEAL_TARGET:-$REVEAL_PARENT}"
      fi
      REVEAL_TARGET_ESC="$(escape_lua "$REVEAL_TARGET")"

      nvim_send "pcall(function() require('code-preview.neo_tree').refresh() end)" || true

      if [[ -n "$REVEAL_DIR" ]]; then
        REVEAL_DIR_ESC="$(escape_lua "$REVEAL_DIR")"
        nvim_send "vim.defer_fn(function() pcall(function() require('code-preview.neo_tree').reveal('$REVEAL_TARGET_ESC', '$REVEAL_DIR_ESC') end) end, 300)" || true
      else
        nvim_send "vim.defer_fn(function() pcall(function() require('code-preview.neo_tree').reveal('$REVEAL_TARGET_ESC') end) end, 300)" || true
      fi
    fi

    nvim_send "require('code-preview.diff').show_diff('$ORIG_ESC', '$PROP_ESC', '$DISPLAY_ESC', '$FILE_PATH_ESC')" || true
  fi
fi

# --- Backend-specific output ---

# Permission decision: when defer_claude_permissions is true (or nvim is
# unreachable), produce no output and let Claude Code's own permission
# settings (bypass, ask, allowlist) decide. Otherwise return "ask" to
# prompt the user for every edit, preserving the default review workflow.
if [[ "${CODE_PREVIEW_BACKEND:-}" == "claudecode" && "$HAS_NVIM" == "true" && "$DEFER_PERMISSIONS" != "true" ]]; then
  REASON="Diff preview sent to Neovim. Review before accepting."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$REASON"
fi
