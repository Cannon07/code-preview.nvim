#!/usr/bin/env bash
# nvim-socket.sh — Discovers the running Neovim's RPC socket path.
#
# Usage:
#   source bin/nvim-socket.sh [project_cwd]
#   echo "$NVIM_SOCKET"
#
# If project_cwd is provided, prefers the Neovim instance whose working
# directory matches (or is a parent of) that path. Falls back to the first
# valid socket if no CWD match is found.
#
# Sets NVIM_SOCKET to the path of a valid, responsive Neovim socket.

_NVIM_SOCKET_CWD="${1:-}"

# Get the cwd of a process by PID (macOS + Linux compatible)
_get_pid_cwd() {
  local pid=$1
  if [[ -d "/proc/$pid/cwd" ]]; then
    readlink "/proc/$pid/cwd" 2>/dev/null || true
  else
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n/' | head -1 | cut -c2- || true
  fi
}

find_nvim_socket() {
  # Disable errexit locally — this function is often sourced from scripts
  # that use set -euo pipefail, and we don't want dead processes or empty
  # globs to abort execution.
  local _oldopts
  _oldopts="$(set +o)"  # save all current set options
  set +e +o pipefail

  local project_cwd="${1:-}"
  local result=""

  # 1. Check explicit env var first
  if [[ -n "${NVIM_LISTEN_ADDRESS:-}" ]] && [[ -S "$NVIM_LISTEN_ADDRESS" ]]; then
    result="$NVIM_LISTEN_ADDRESS"
    eval "$_oldopts"
    echo "$result"
    return 0
  fi

  # Collect all live sockets as "pid:socket_path" entries
  local live_sockets=()
  local socket pid

  # 2. Scan macOS /var/folders paths
  local _glob_out
  _glob_out="$(compgen -G '/var/folders/*/*/T/nvim.*/*/nvim.*.0' 2>/dev/null)" || true
  if [[ -n "$_glob_out" ]]; then
    while IFS= read -r socket; do
      if [[ -S "$socket" ]]; then
        pid=$(basename "$socket" | sed 's/^nvim\.\([0-9]*\)\.0$/\1/')
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
          live_sockets+=("$pid:$socket")
        fi
      fi
    done <<< "$_glob_out"
  fi

  # 3. Scan /tmp paths (Linux and some macOS setups)
  local _tmp_glob_out
  _tmp_glob_out="$(compgen -G '/tmp/nvim.*/0' 2>/dev/null)" || true
  if [[ -n "$_tmp_glob_out" ]]; then
    while IFS= read -r socket; do
      if [[ -S "$socket" ]]; then
        pid=$(echo "$socket" | grep -oE 'nvim\.[0-9]+' | grep -oE '[0-9]+')
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
          live_sockets+=("$pid:$socket")
        fi
      fi
    done <<< "$_tmp_glob_out"
  fi

  if [[ ${#live_sockets[@]} -eq 0 ]]; then
    eval "$_oldopts"
    return 1
  fi

  # 4. If project_cwd given, prefer the socket whose nvim has a matching cwd
  if [[ -n "$project_cwd" ]]; then
    local entry nvim_cwd
    for entry in "${live_sockets[@]}"; do
      pid="${entry%%:*}"
      socket="${entry#*:}"
      nvim_cwd="$(_get_pid_cwd "$pid")"
      # Check if nvim's cwd matches or is a parent of project_cwd
      if [[ -n "$nvim_cwd" ]] && [[ "$project_cwd" == "$nvim_cwd" || "$project_cwd" == "$nvim_cwd/"* ]]; then
        result="$socket"
        break
      fi
    done
  fi

  # 5. Fallback to the first live socket
  if [[ -z "$result" ]]; then
    result="${live_sockets[0]#*:}"
  fi

  eval "$_oldopts"
  echo "$result"
  return 0
}

NVIM_SOCKET="$(find_nvim_socket "$_NVIM_SOCKET_CWD")" || true
export NVIM_SOCKET
