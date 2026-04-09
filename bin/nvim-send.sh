#!/usr/bin/env bash
# nvim-send.sh — Send a Lua command to Neovim via RPC.
#
# Usage:
#   source bin/nvim-send.sh
#   nvim_send "require('claude-preview.diff').show_diff('a', 'b', 'c')"
#
# Depends on nvim-socket.sh being sourced first (NVIM_SOCKET must be set).

# Escape a string for use inside a Lua single-quoted string literal
escape_lua() {
  echo "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"
}

# Send a Lua command to Neovim via --remote-expr (synchronous).
# Writes to a temp file and uses execute('luafile ...') so that:
#   - There are no command-line length limits
#   - No keystrokes are simulated (safe inside terminal buffers)
#   - The call blocks until Neovim finishes executing the Lua
# Returns 0 if sent, 1 if no socket available
nvim_send() {
  local lua_cmd="$1"
  if [[ -z "${NVIM_SOCKET:-}" ]]; then
    return 1
  fi
  local tmp_lua
  tmp_lua="$(mktemp /tmp/claude-preview-nvim-cmd.XXXXXX)"
  printf '%s' "$lua_cmd" > "$tmp_lua"
  nvim --server "$NVIM_SOCKET" --remote-expr "execute('luafile $tmp_lua')" >/dev/null 2>&1
  local rc=$?
  rm -f "$tmp_lua"
  return $rc
}
