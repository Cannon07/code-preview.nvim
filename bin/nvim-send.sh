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

# Send a Lua command to Neovim via --remote-send
# Returns 0 if sent, 1 if no socket available
nvim_send() {
  local lua_cmd="$1"
  if [[ -z "${NVIM_SOCKET:-}" ]]; then
    return 1
  fi
  nvim --server "$NVIM_SOCKET" --remote-send ":lua $lua_cmd<CR>" 2>/dev/null
}
