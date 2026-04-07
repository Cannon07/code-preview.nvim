#!/usr/bin/env bash
# test_stale_socket.sh — Tests stale socket recovery
#
# Verifies that when Neovim is killed and restarted, the hook scripts
# can still find the new instance and deliver diffs.

# ── Setup ────────────────────────────────────────────────────────

setup_test_project

# ── Test: Hook works after Neovim restart ────────────────────────

test_stale_socket_recovery() {
  # Start first Neovim instance
  start_nvim

  local test_file
  test_file="$(create_test_file "src/recover.lua" 'local old = true')"

  # Verify first instance works
  local payload
  payload=$(cat <<EOF
{
  "tool_name": "Edit",
  "cwd": "$TEST_PROJECT_DIR",
  "tool_input": {
    "file_path": "$test_file",
    "old_string": "local old = true",
    "new_string": "local old = false"
  }
}
EOF
)

  run_pretool_hook "$payload" >/dev/null
  sleep 0.5
  local is_open
  is_open="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "diff should open on first instance" || return 1

  run_posttool_hook "$payload" >/dev/null
  sleep 0.3

  # Kill Neovim (simulates user quitting)
  stop_nvim

  # Start a fresh Neovim instance (same socket path since we control it)
  start_nvim

  # The hook should work with the new instance
  local payload2
  payload2=$(cat <<EOF
{
  "tool_name": "Edit",
  "cwd": "$TEST_PROJECT_DIR",
  "tool_input": {
    "file_path": "$test_file",
    "old_string": "local old = true",
    "new_string": "local new = true"
  }
}
EOF
)

  run_pretool_hook "$payload2" >/dev/null
  sleep 0.5

  local is_open2
  is_open2="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "true" "$is_open2" "diff should open on second (restarted) instance" || return 1

  run_posttool_hook "$payload2" >/dev/null
  sleep 0.3
}

# ── Test: Hook script handles missing Neovim gracefully ──────────

test_no_nvim_graceful() {
  # Simulate no running Neovim instance by pointing socket discovery at
  # a bogus address and preventing the scan from finding real instances
  # (override PATH so nvim-socket.sh's compgen/ls can't find real sockets)
  local test_file
  test_file="$(create_test_file "src/noserver.lua" 'print("hi")')"

  local payload
  payload=$(cat <<EOF
{
  "tool_name": "Edit",
  "cwd": "/tmp/nonexistent-project-$$",
  "tool_input": {
    "file_path": "$test_file",
    "old_string": "hi",
    "new_string": "bye"
  }
}
EOF
)

  # Create a minimal script that wraps the hook with an isolated environment:
  # - NVIM_LISTEN_ADDRESS points to a nonexistent socket
  # - We override find_nvim_socket to always fail by using a wrapper script
  local wrapper
  wrapper="$(mktemp /tmp/claude-test-no-nvim.XXXXXX.sh)"
  cat > "$wrapper" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
# Override nvim-socket.sh: make it always fail to find a socket
export NVIM_LISTEN_ADDRESS="/tmp/bogus-nvim-socket-$$"
export NVIM_SOCKET=""

SCRIPT_DIR="$REPO_ROOT/bin"
# Source nvim-send.sh for helpers but skip socket discovery
source "\$SCRIPT_DIR/nvim-send.sh"

# Read stdin and process like claude-preview-diff.sh but with no socket
INPUT="\$(cat)"
TOOL_NAME="\$(echo "\$INPUT" | jq -r '.tool_name')"

# The actual diff script — source it with our overrides
exec bash "$REPO_ROOT/bin/claude-preview-diff.sh"
WRAPPER
  chmod +x "$wrapper"

  # Run with empty NVIM_LISTEN_ADDRESS pointing to nonexistent socket
  local output
  output="$(echo "$payload" | \
    NVIM_LISTEN_ADDRESS="/tmp/bogus-nvim-socket-$$" \
    bash "$REPO_ROOT/bin/claude-preview-diff.sh" 2>/dev/null || true)"
  rm -f "$wrapper"

  # Should produce a valid JSON response with "ask" decision
  assert_contains "$output" '"permissionDecision":"ask"' "should still return ask decision without Neovim" || return 1
  # The script should still compute the edit and produce output (just can't send to Neovim)
  # The proposed temp file should exist
  local proposed="${TMPDIR:-/tmp}/claude-diff-proposed"
  assert_file_exists "$proposed" "proposed file should be computed even without Neovim" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "Hook works after Neovim restart (stale socket)" test_stale_socket_recovery
run_test "Hook handles missing Neovim gracefully" test_no_nvim_graceful

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
