#!/usr/bin/env bash
# code-preview-diff.sh — PreToolUse hook adapter for OpenAI Codex CLI.
#
# Translates Codex's hook payload (stdin JSON with tool_name/tool_input) into
# the normalized {tool_name, cwd, tool_input} format consumed by
# bin/core-pre-tool.sh, then delegates to it.
#
# Field mapping:
#   apply_patch        → ApplyPatch  (tool_input.command holds the patch text;
#                                     we move it under .patch_text)
#   ApplyPatch         → ApplyPatch  (passthrough; canonical name)
#   Edit               → Edit        (passthrough; assumes Claude-Code-style
#                                     {file_path, old_string, new_string})
#   Write              → Write       (passthrough; assumes {file_path, content})
#   Bash               → Bash        (passthrough)
#   read/glob/MCP/...  → ignored
#
# Note: today's Codex models route all file edits through `apply_patch`. The
# Edit/Write branches exist defensively in case a future Codex version (or
# an MCP server) emits those names with Claude-Code-style field shapes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"
export CODE_PREVIEW_BACKEND="codex"

INPUT="$(cat)"

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""')"

# Skip noisy/no-op tools before the expensive socket/log-setup RPC.
case "$TOOL" in
  ""|read|view|glob|grep|ls|list_files) exit 0 ;;
esac
# MCP tools follow `mcp__server__name`; we don't preview them.
case "$TOOL" in
  mcp__*) exit 0 ;;
esac

# Logging — mirrors copilot/code-preview-diff.sh. Gated on `debug = true`.
log() { :; }
# shellcheck source=/dev/null
source "$BIN_DIR/nvim-socket.sh" "$CWD" 2>/dev/null || true
# shellcheck source=/dev/null
source "$BIN_DIR/nvim-send.sh" 2>/dev/null || true
if [[ -n "${NVIM_SOCKET:-}" ]]; then
  _CTX=$(nvim --server "$NVIM_SOCKET" --remote-expr "luaeval(\"vim.json.encode({debug=require('code-preview.log').is_enabled(),log_file=require('code-preview.log').get_log_path() or ''})\")" 2>/dev/null || echo '{}')
  _DBG=$(echo "$_CTX" | jq -r '.debug // false' 2>/dev/null)
  _LOG=$(echo "$_CTX" | jq -r '.log_file // ""' 2>/dev/null)
  if [[ "$_DBG" == "true" && -n "$_LOG" ]]; then
    log() { printf '[%s] [INFO] codex/pre: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$_LOG"; }
  fi
fi

log "tool=$TOOL cwd=$CWD"

case "$TOOL" in
  apply_patch)
    # Codex stores the raw `*** Begin Patch ... *** End Patch` text in
    # tool_input.command. Our ApplyPatch handler in core-pre-tool.sh reads
    # tool_input.patch_text, so move the field.
    PATCH="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')"
    if [[ -z "$PATCH" ]]; then
      log "apply_patch with empty/missing patch text — skipping"
      exit 0
    fi
    NORMALIZED="$(printf '%s' "$INPUT" | jq '{
      tool_name: "ApplyPatch",
      cwd: .cwd,
      tool_input: { patch_text: (.tool_input.command // "") }
    }')"
    ;;

  ApplyPatch|Edit|Write)
    # Edit/Write-family tools require a non-empty file_path. Without it,
    # core-pre-tool.sh would push a broken diff downstream.
    FP="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')"
    if [[ -z "$FP" ]]; then
      log "$TOOL with empty/missing file_path — skipping"
      exit 0
    fi
    NORMALIZED="$(printf '%s' "$INPUT" | jq '{
      tool_name: .tool_name,
      cwd: .cwd,
      tool_input: .tool_input
    }')"
    ;;

  Bash)
    # Bash needs a non-empty command to be useful (rm detection, shell-write
    # detection both run on the command string).
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')"
    if [[ -z "$CMD" ]]; then
      log "Bash with empty/missing command — skipping"
      exit 0
    fi
    NORMALIZED="$(printf '%s' "$INPUT" | jq '{
      tool_name: .tool_name,
      cwd: .cwd,
      tool_input: .tool_input
    }')"
    ;;

  *)
    log "unhandled tool=$TOOL — exiting"
    exit 0
    ;;
esac

log "translated tool=$TOOL → $(printf '%s' "$NORMALIZED" | jq -c '{tool_name, file: .tool_input.file_path // "", has_patch: (.tool_input.patch_text != null)}' 2>/dev/null || echo 'parse-error')"

printf '%s' "$NORMALIZED" | "$BIN_DIR/core-pre-tool.sh"
