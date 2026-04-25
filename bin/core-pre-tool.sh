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
#   CODE_PREVIEW_BACKEND  — "claudecode" | "opencode" | "copilot". Only
#                           "claudecode" emits the permissionDecision JSON
#                           on stdout; other values suppress it.

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

# Set up logging early so all code paths can use it
log_pre() { :; }
if [[ "$HAS_NVIM" == "true" ]]; then
  _PRE_CTX=$(nvim --server "$NVIM_SOCKET" --remote-expr "luaeval(\"vim.json.encode({debug=require('code-preview.log').is_enabled(),log_file=require('code-preview.log').get_log_path() or ''})\")" 2>/dev/null || echo '{}')
  _PRE_DEBUG=$(echo "$_PRE_CTX" | jq -r '.debug // false')
  _PRE_LOG_FILE=$(echo "$_PRE_CTX" | jq -r '.log_file // ""')
  if [[ "$_PRE_DEBUG" == "true" && -n "$_PRE_LOG_FILE" ]]; then
    log_pre() { printf '[%s] [INFO] core-pre-tool.sh: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$_PRE_LOG_FILE"; }
  fi
fi

log_pre "tool=$TOOL_NAME has_nvim=$HAS_NVIM"

TMPDIR="${TMPDIR:-/tmp}"
# Use unique temp files per hook invocation so rapid-fire pre-hooks
# (OpenCode fires all before-hooks before any after-hooks) don't clobber
# each other's diff content.
HOOK_ID="$$"
ORIG_FILE="$TMPDIR/claude-diff-original-$HOOK_ID"
PROP_FILE="$TMPDIR/claude-diff-proposed-$HOOK_ID"

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

    NVIM_LISTEN_ADDRESS= nvim --headless -l "$SCRIPT_DIR/apply-edit.lua" "$FILE_PATH" "$OLD_STRING" "$NEW_STRING" "$REPLACE_ALL" "$PROP_FILE" || true
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
    PATCH_TEXT="$(echo "$INPUT" | jq -r '.tool_input.patch_text // empty')"
    if [[ -z "$PATCH_TEXT" ]]; then
      log_pre "ApplyPatch: empty patch_text, exiting"
      exit 0
    fi
    log_pre "ApplyPatch: received patch (${#PATCH_TEXT} chars)"

    # Write patch JSON to a temp file for the Lua parser
    PATCH_JSON="$TMPDIR/claude-patch-input-$HOOK_ID.json"
    echo "$INPUT" | jq '{patch_text: .tool_input.patch_text}' > "$PATCH_JSON"

    PATCH_OUTDIR="$TMPDIR/claude-patch-out-$HOOK_ID"
    mkdir -p "$PATCH_OUTDIR"

    # Parse the custom patch format and compute per-file original/proposed
    log_pre "ApplyPatch: running apply-patch.lua"
    NVIM_LISTEN_ADDRESS= nvim --headless -l "$SCRIPT_DIR/apply-patch.lua" "$PATCH_JSON" "$CWD" "$PATCH_OUTDIR" 2>/dev/null || true

    RESULTS_FILE="$PATCH_OUTDIR/files.json"
    if [[ ! -f "$RESULTS_FILE" ]]; then
      log_pre "ApplyPatch: apply-patch.lua produced no results"
      rm -f "$PATCH_JSON"
      rm -rf "$PATCH_OUTDIR"
      exit 0
    fi

    # Read results and send each file's diff to nvim
    FILE_COUNT=$(jq 'length' "$RESULTS_FILE")
    log_pre "ApplyPatch: parsed $FILE_COUNT file(s)"

    for i in $(seq 0 $((FILE_COUNT - 1))); do
      PATCH_FILE_PATH=$(jq -r ".[$i].path" "$RESULTS_FILE")
      REL_PATH=$(jq -r ".[$i].rel_path" "$RESULTS_FILE")
      ACTION=$(jq -r ".[$i].action" "$RESULTS_FILE")
      PATCH_ORIG=$(jq -r ".[$i].orig" "$RESULTS_FILE")
      PATCH_PROP=$(jq -r ".[$i].prop" "$RESULTS_FILE")

      log_pre "ApplyPatch: file=$REL_PATH action=$ACTION"

      if [[ "$HAS_NVIM" == "true" ]]; then
        display_esc="$(escape_lua "$REL_PATH")"
        orig_esc="$(escape_lua "$PATCH_ORIG")"
        prop_esc="$(escape_lua "$PATCH_PROP")"
        fpath_esc="$(escape_lua "$PATCH_FILE_PATH")"

        HOOK_CTX=$(nvim --server "$NVIM_SOCKET" --remote-expr "luaeval(\"require('code-preview').hook_context('${fpath_esc}')\")" 2>/dev/null || echo '{}')
        VISIBLE_ONLY=$(echo "$HOOK_CTX" | jq -r '.visible_only // false')
        FILE_VISIBLE=$(echo "$HOOK_CTX" | jq -r '.file_visible // false')

        SHOULD_SHOW="1"
        if [[ "$VISIBLE_ONLY" == "true" && "$FILE_VISIBLE" != "true" ]]; then
          SHOULD_SHOW="0"
          log_pre "ApplyPatch: skipping diff for $REL_PATH (visible_only)"
        fi

        if [[ "$SHOULD_SHOW" == "1" ]]; then
          log_pre "ApplyPatch: sending diff for $REL_PATH to nvim"
          nvim_send "require('code-preview.diff').show_diff('$orig_esc', '$prop_esc', '$display_esc', '$fpath_esc')" || true
        fi
      else
        log_pre "ApplyPatch: no nvim connection, skipping diff for $REL_PATH"
      fi
    done

    rm -f "$PATCH_JSON"
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

  # Query config + file visibility from nvim in a single RPC call.
  # Neo-tree indicator/reveal is now driven from lua/code-preview/diff.lua
  # (inside show_diff), so we only need visibility + permission fields here.
  HOOK_CTX=$(nvim --server "$NVIM_SOCKET" --remote-expr "luaeval(\"require('code-preview').hook_context('${FILE_PATH_ESC}')\")" 2>/dev/null || echo '{}')
  VISIBLE_ONLY=$(echo "$HOOK_CTX" | jq -r '.visible_only // false')
  FILE_VISIBLE=$(echo "$HOOK_CTX" | jq -r '.file_visible // false')
  DEFER_PERMISSIONS=$(echo "$HOOK_CTX" | jq -r 'if .defer_claude_permissions == true then "true" else "false" end')

  log_pre "file=$FILE_PATH visible_only=$VISIBLE_ONLY file_visible=$FILE_VISIBLE"

  # Decide whether to show the diff — skip nvim UI entirely when visible_only
  # is on and the file isn't in any visible window.
  SHOULD_SHOW="1"
  if [[ "$VISIBLE_ONLY" == "true" && "$FILE_VISIBLE" != "true" ]]; then
    SHOULD_SHOW="0"
    log_pre "skipping diff: visible_only=true, file not visible"
  fi

  if [[ "$SHOULD_SHOW" == "1" ]]; then
    log_pre "sending diff to nvim (layout via config)"
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
