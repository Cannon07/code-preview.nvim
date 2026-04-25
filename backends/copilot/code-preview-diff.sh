#!/usr/bin/env bash
# code-preview-diff.sh — PreToolUse hook adapter for GitHub Copilot CLI.
#
# Translates Copilot's hook payload (stdin JSON with toolName/toolArgs) into
# the normalized {tool_name, cwd, tool_input} format consumed by
# bin/core-pre-tool.sh, then delegates to it.
#
# Field mapping:
#   apply_patch      → ApplyPatch  (toolArgs is raw patch text)
#   edit/str_replace → Edit        ({path, old_str, new_str})
#   create/write     → Write       ({path, file_text | content})
#   bash             → Bash        ({command, description})
#   view/glob/...    → ignored
#
# Note: toolArgs is a JSON-encoded string in preToolUse and an object in
# postToolUse; we normalize both to a string so downstream parsing is uniform.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"
export CODE_PREVIEW_BACKEND="copilot"

INPUT="$(cat)"

TOOL="$(printf '%s' "$INPUT" | jq -r '.toolName // ""')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""')"

# Noise tools never produce a preview — bail out before the expensive
# socket/log-setup RPC so the log stays clean.
case "$TOOL" in
  ""|view|glob|grep|ls|report_intent) exit 0 ;;
esac

# Logging — mirrors core-pre-tool.sh. Gated on `debug = true` in setup().
log() { :; }
# shellcheck source=/dev/null
source "$BIN_DIR/nvim-socket.sh" "$CWD" 2>/dev/null || true
# shellcheck source=/dev/null
source "$BIN_DIR/nvim-send.sh" 2>/dev/null || true
_NVIM_SERVERNAME=""
_NVIM_CWD=""
if [[ -n "${NVIM_SOCKET:-}" ]]; then
  _CTX=$(nvim --server "$NVIM_SOCKET" --remote-expr "luaeval(\"vim.json.encode({debug=require('code-preview.log').is_enabled(),log_file=require('code-preview.log').get_log_path() or '',servername=vim.v.servername,cwd=vim.fn.getcwd()})\")" 2>/dev/null || echo '{}')
  _DBG=$(echo "$_CTX" | jq -r '.debug // false' 2>/dev/null)
  _LOG=$(echo "$_CTX" | jq -r '.log_file // ""' 2>/dev/null)
  _NVIM_SERVERNAME=$(echo "$_CTX" | jq -r '.servername // ""' 2>/dev/null)
  _NVIM_CWD=$(echo "$_CTX" | jq -r '.cwd // ""' 2>/dev/null)
  if [[ "$_DBG" == "true" && -n "$_LOG" ]]; then
    log() { printf '[%s] [INFO] copilot/pre: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$_LOG"; }
  fi
fi

log "tool=$TOOL servername=${_NVIM_SERVERNAME:-<none>} nvim_cwd=${_NVIM_CWD:-<none>} hook_cwd=$CWD"

# Normalize toolArgs to a raw string. For JSON-object tools this becomes the
# stringified JSON; for apply_patch it's the raw patch text.
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
    NORMALIZED="$(jq -n \
      --arg cwd "$CWD" \
      --arg fp "$FP" \
      --arg os "$(arg .old_str)" \
      --arg ns "$(arg .new_str)" \
      '{tool_name:"Edit", cwd:$cwd,
        tool_input:{file_path:$fp, old_string:$os, new_string:$ns, replace_all:false}}')"
    ;;

  create|write)
    FP="$(resolve_path "$(arg .path)")"
    # Copilot's create uses file_text; fall back to content for other models.
    CONTENT="$(printf '%s' "$RAW_ARGS" | jq -r '.file_text // .content // ""')"
    NORMALIZED="$(jq -n --arg cwd "$CWD" --arg fp "$FP" --arg c "$CONTENT" \
      '{tool_name:"Write", cwd:$cwd, tool_input:{file_path:$fp, content:$c}}')"
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

# Guard against malformed payloads (missing toolArgs fields). Sending an
# empty path or command downstream produces a broken/empty diff; a clean
# skip is preferable. apply_patch is already resilient — apply-patch.lua
# parses zero files from an empty patch and exits cleanly.
case "$TOOL" in
  edit|str_replace|create|write)
    if [[ -z "$FP" ]]; then
      log "empty file path for tool=$TOOL — skipping"
      exit 0
    fi
    ;;
  bash)
    if [[ -z "$CMD" ]]; then
      log "empty command for bash — skipping"
      exit 0
    fi
    ;;
esac

log "translated tool=$TOOL → $(printf '%s' "$NORMALIZED" | jq -c '{tool_name, file: .tool_input.file_path // "", has_patch: (.tool_input.patch_text != null)}' 2>/dev/null || echo 'parse-error')"

printf '%s' "$NORMALIZED" | "$BIN_DIR/core-pre-tool.sh"
