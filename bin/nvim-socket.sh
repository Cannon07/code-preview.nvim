#!/usr/bin/env bash
# nvim-socket.sh — Discovers the running Neovim's RPC socket path.
#
# Usage:
#   source bin/nvim-socket.sh
#   echo "$NVIM_SOCKET"
#
# Sets NVIM_SOCKET to the path of a valid, responsive Neovim socket.
# Returns exit code 1 if no socket is found.

find_nvim_socket() {
  # 1. Check explicit env var first
  if [[ -n "${NVIM_LISTEN_ADDRESS:-}" ]] && [[ -S "$NVIM_LISTEN_ADDRESS" ]]; then
    echo "$NVIM_LISTEN_ADDRESS"
    return 0
  fi

  # 2. Scan macOS /var/folders paths (where Neovim puts sockets on macOS)
  #    Extract PID from socket filename (nvim.<PID>.0) and verify process is alive
  local socket pid
  local sockets
  sockets=($(compgen -G '/var/folders/*/*/T/nvim.*/*/nvim.*.0' 2>/dev/null)) || true
  for socket in "${sockets[@]}"; do
    if [[ -S "$socket" ]]; then
      pid=$(basename "$socket" | sed 's/^nvim\.\([0-9]*\)\.0$/\1/')
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "$socket"
        return 0
      fi
    fi
  done

  # 3. Scan /tmp paths (Linux and some macOS setups)
  local tmp_sockets
  tmp_sockets=($(compgen -G '/tmp/nvim.*/0' 2>/dev/null)) || true
  for socket in "${tmp_sockets[@]}"; do
    if [[ -S "$socket" ]]; then
      pid=$(echo "$socket" | grep -oE 'nvim\.[0-9]+' | grep -oE '[0-9]+')
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "$socket"
        return 0
      fi
    fi
  done

  return 1
}

NVIM_SOCKET="$(find_nvim_socket || true)"
export NVIM_SOCKET
