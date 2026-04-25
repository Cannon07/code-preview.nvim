#!/usr/bin/env bash
# code-close-diff.sh — PostToolUse hook adapter for GitHub Copilot CLI.
#
# Mirrors the translation in code-preview-diff.sh and delegates to
# bin/core-post-tool.sh. Only the fields core-post-tool.sh reads are
# populated (tool_name, cwd, file_path or patch_text).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"
export CODE_PREVIEW_BACKEND="copilot"

INPUT="$(cat)"

TOOL="$(printf '%s' "$INPUT" | jq -r '.toolName // ""')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""')"

case "$TOOL" in
  ""|view|glob|grep|ls|report_intent) exit 0 ;;
esac

# Logging — gated on `debug = true` in setup().
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
    log() { printf '[%s] [INFO] copilot/post: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$_LOG"; }
  fi
fi

log "tool=$TOOL"

RAW_ARGS="$(printf '%s' "$INPUT" | jq -r '.toolArgs // "" | if type == "string" then . else tojson end')"

# Bind the key as data via --arg, not interpolated into the jq program.
# Supports single-key lookup only (no dotted paths) — all current callers
# pass a single field like `.path`, `.command`, etc.
arg() { printf '%s' "$RAW_ARGS" | jq -r --arg k "${1#.}" '.[$k] // ""'; }

resolve_path() {
  local p="$1"
  if [[ -z "$p" ]]; then printf ''; return; fi
  if [[ "$p" != /* ]]; then printf '%s/%s' "$CWD" "$p"; else printf '%s' "$p"; fi
}

case "$TOOL" in
  apply_patch)
    NORMALIZED="$(jq -n --arg cwd "$CWD" --arg patch "$RAW_ARGS" \
      '{tool_name:"ApplyPatch", cwd:$cwd, tool_input:{patch_text:$patch}}')"
    ;;

  edit|str_replace)
    FP="$(resolve_path "$(arg .path)")"
    NORMALIZED="$(jq -n --arg cwd "$CWD" --arg fp "$FP" \
      '{tool_name:"Edit", cwd:$cwd, tool_input:{file_path:$fp}}')"
    ;;

  create|write)
    FP="$(resolve_path "$(arg .path)")"
    NORMALIZED="$(jq -n --arg cwd "$CWD" --arg fp "$FP" \
      '{tool_name:"Write", cwd:$cwd, tool_input:{file_path:$fp}}')"
    ;;

  bash)
    CMD="$(arg .command)"
    NORMALIZED="$(jq -n --arg cwd "$CWD" --arg cmd "$CMD" \
      '{tool_name:"Bash", cwd:$cwd, tool_input:{command:$cmd}}')"
    ;;

  *)
    log "unhandled tool=$TOOL — exiting"
    exit 0
    ;;
esac

log "translated tool=$TOOL → closing"

printf '%s' "$NORMALIZED" | "$BIN_DIR/core-post-tool.sh"
