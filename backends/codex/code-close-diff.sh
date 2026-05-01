#!/usr/bin/env bash
# code-close-diff.sh — PostToolUse hook adapter for OpenAI Codex CLI.
#
# Mirrors the translation in code-preview-diff.sh and delegates to
# bin/core-post-tool.sh. Only the fields core-post-tool.sh reads are
# populated (tool_name, cwd, file_path or patch_text).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"
export CODE_PREVIEW_BACKEND="codex"

INPUT="$(cat)"

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""')"

case "$TOOL" in
  ""|read|view|glob|grep|ls|list_files) exit 0 ;;
esac
case "$TOOL" in
  mcp__*) exit 0 ;;
esac

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
    log() { printf '[%s] [INFO] codex/post: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$_LOG"; }
  fi
fi

log "tool=$TOOL"

case "$TOOL" in
  apply_patch)
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

log "translated tool=$TOOL → closing"

printf '%s' "$NORMALIZED" | "$BIN_DIR/core-post-tool.sh"
