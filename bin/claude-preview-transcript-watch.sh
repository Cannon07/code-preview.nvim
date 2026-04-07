#!/usr/bin/env bash
# claude-preview-transcript-watch.sh — shared transcript watcher helpers
#
# Sourced by claude-preview-diff.sh and claude-close-diff.sh.

claude_preview_watch_state_key() {
  local transcript_path="$1"
  local tool_use_id="$2"
  printf '%s\0%s' "$transcript_path" "$tool_use_id" | cksum | awk '{print $1}'
}

claude_preview_watch_state_dir() {
  local transcript_path="$1"
  local tool_use_id="$2"
  local key
  key="$(claude_preview_watch_state_key "$transcript_path" "$tool_use_id")"
  printf '%s/claude-preview-watch-%s' "${TMPDIR:-/tmp}" "$key"
}

claude_preview_watch_pidfile() {
  local transcript_path="$1"
  local tool_use_id="$2"
  printf '%s/pid' "$(claude_preview_watch_state_dir "$transcript_path" "$tool_use_id")"
}

claude_preview_watch_stopfile() {
  local transcript_path="$1"
  local tool_use_id="$2"
  printf '%s/stop' "$(claude_preview_watch_state_dir "$transcript_path" "$tool_use_id")"
}

claude_preview_watch_fifo() {
  local transcript_path="$1"
  local tool_use_id="$2"
  printf '%s/transcript.fifo' "$(claude_preview_watch_state_dir "$transcript_path" "$tool_use_id")"
}

claude_preview_stop_transcript_watcher() {
  local transcript_path="$1"
  local tool_use_id="$2"
  local state_dir pidfile stopfile pid

  state_dir="$(claude_preview_watch_state_dir "$transcript_path" "$tool_use_id")"
  pidfile="$(claude_preview_watch_pidfile "$transcript_path" "$tool_use_id")"
  stopfile="$(claude_preview_watch_stopfile "$transcript_path" "$tool_use_id")"

  if [[ ! -d "$state_dir" ]]; then
    return 0
  fi

  : > "$stopfile"

  if [[ -r "$pidfile" ]]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  fi
}

claude_preview_line_is_rejection() {
  local line="$1"
  local tool_use_id="$2"

  printf '%s\n' "$line" | jq -e --arg tool_use_id "$tool_use_id" '
    (.message.content // []) |
    any(.tool_use_id == $tool_use_id and (.is_error // false) == true)
  ' >/dev/null 2>&1
}

claude_preview_nvim_diff_is_open() {
  [[ -n "${NVIM_SOCKET:-}" ]] || return 1

  local result
  result="$(
    nvim --server "$NVIM_SOCKET" --remote-expr \
      "luaeval(\"require('claude-preview.diff').is_open() and 1 or 0\")" \
      2>/dev/null
  )" || return 1

  [[ "$result" == "1" ]]
}

claude_preview_close_diff_for_rejection() {
  [[ -n "${NVIM_SOCKET:-}" ]] || return 1
  nvim_send "if require('claude-preview.diff').is_open() then pcall(function() require('claude-preview.changes').clear_all() end) pcall(function() require('claude-preview.diff').close_diff() end) end"
}

claude_preview_watch_transcript() {
  local transcript_path="$1"
  local tool_use_id="$2"
  local state_dir pidfile stopfile fifo tail_pid deadline next_probe line

  state_dir="$(claude_preview_watch_state_dir "$transcript_path" "$tool_use_id")"
  pidfile="$(claude_preview_watch_pidfile "$transcript_path" "$tool_use_id")"
  stopfile="$(claude_preview_watch_stopfile "$transcript_path" "$tool_use_id")"
  fifo="$(claude_preview_watch_fifo "$transcript_path" "$tool_use_id")"

  mkdir -p "$state_dir"
  rm -f "$pidfile" "$stopfile" "$fifo"

  trap '
    if [[ -n "${tail_pid:-}" ]]; then
      kill "$tail_pid" 2>/dev/null || true
      wait "$tail_pid" 2>/dev/null || true
    fi
    rm -f "$pidfile" "$stopfile" "$fifo"
    rmdir "$state_dir" 2>/dev/null || true
  ' EXIT
  trap '' HUP

  mkfifo "$fifo"
  tail -n0 -F "$transcript_path" >"$fifo" 2>/dev/null &
  tail_pid=$!
  exec 3<"$fifo"
  rm -f "$fifo"

  deadline=$((SECONDS + 120))
  next_probe=$SECONDS

  while (( SECONDS < deadline )); do
    if [[ -f "$stopfile" ]]; then
      break
    fi

    if (( SECONDS >= next_probe )); then
      if ! claude_preview_nvim_diff_is_open; then
        break
      fi
      next_probe=$((SECONDS + 2))
    fi

    if ! IFS= read -r -t 1 line <&3; then
      if ! kill -0 "$tail_pid" 2>/dev/null; then
        break
      fi
      continue
    fi

    if claude_preview_line_is_rejection "$line" "$tool_use_id"; then
      rm -f "${TMPDIR:-/tmp}/claude-diff-original" "${TMPDIR:-/tmp}/claude-diff-proposed"
      claude_preview_close_diff_for_rejection || true
      break
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  if [[ $# -lt 2 ]]; then
    echo "usage: $0 TRANSCRIPT_PATH TOOL_USE_ID" >&2
    exit 2
  fi
  source "$(dirname "$0")/nvim-send.sh"
  claude_preview_watch_transcript "$1" "$2"
fi
