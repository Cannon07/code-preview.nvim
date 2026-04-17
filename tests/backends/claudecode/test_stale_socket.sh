#!/usr/bin/env bash
# test_stale_socket.sh — Tests stale socket recovery
#
# Verifies that when Neovim is killed and restarted, the hook scripts
# can still find the new instance and deliver diffs.

# ── Setup ────────────────────────────────────────────────────────

setup_test_project

# ── Test: Hook works after Neovim restart ────────────────────────

test_stale_socket_recovery() {
  # Start the first Neovim instance on a scanner-compatible socket path. The
  # hook still has to rediscover it by filesystem scan because scan mode clears
  # NVIM_LISTEN_ADDRESS before invoking the hook.
  start_nvim_on_socket "$TEST_PROJECT_DIR"
  local first_socket="$TEST_SOCKET"
  local first_pid="$NVIM_PID"

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

  run_pretool_hook "$payload" scan >/dev/null
  sleep 0.5
  local is_open
  is_open="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "diff should open on first instance" || return 1

  run_posttool_hook "$payload" scan >/dev/null
  sleep 0.3

  # Kill Neovim without cleaning the socket, simulating a stale socket entry.
  crash_nvim
  assert_file_exists "$first_socket" "old socket should remain on disk after crash" || return 1
  if kill -0 "$first_pid" 2>/dev/null; then
    echo "  FAIL: stale Neovim PID should be dead" >&2
    return 1
  fi

  # Start a fresh Neovim instance. Each launch uses a PID-derived socket path,
  # so the new socket will differ from the crashed one.
  start_nvim_on_socket "$TEST_PROJECT_DIR"
  local second_socket="$TEST_SOCKET"
  if [[ "$first_socket" == "$second_socket" ]]; then
    echo "  FAIL: restart should use a different socket path" >&2
    return 1
  fi

  # The hook should rediscover the live socket by scanning, not by trusting a
  # fixed environment variable.
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

  run_pretool_hook "$payload2" scan >/dev/null
  sleep 0.5

  local is_open2
  is_open2="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "true" "$is_open2" "diff should open on second (restarted) instance" || return 1

  run_posttool_hook "$payload2" scan >/dev/null
  sleep 0.3
}

# ── Test: Hook exits cleanly without a guaranteed project match ──

test_no_matching_project_nvim_graceful() {
  # Ensure no test Neovim is running before this test. The payload cwd points
  # at a nonexistent project, so there is no guaranteed matching test instance.
  # The scanner may still fall back to an unrelated ambient nvim, and this test
  # intentionally does not assert socket absence.
  stop_nvim

  local test_file
  test_file="$(create_test_file "src/noserver.lua" 'print("hi")')"

  local hook_tmpdir
  hook_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/claude-test-no-nvim-tmp.XXXXXX")"

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

  # Force scan mode by blanking any inherited NVIM_LISTEN_ADDRESS. The hook
  # must still compute the proposed file and exit cleanly even if there is no
  # project-specific Neovim to attach to.
  local exit_code=0
  echo "$payload" | \
    NVIM_LISTEN_ADDRESS= \
    TMPDIR="$hook_tmpdir" \
    bash "$REPO_ROOT/backends/claudecode/code-preview-diff.sh" >/dev/null 2>&1 || exit_code=$?

  # The hook exits 0 on non-crash paths, including when it cannot identify a
  # project-specific nvim instance.
  assert_eq "0" "$exit_code" "hook must exit 0 without a guaranteed project nvim match" || return 1

  # The proposed temp file must exist (PID-suffixed): headless nvim computed the edit.
  local proposed
  proposed="$(ls -1t "$hook_tmpdir"/claude-diff-proposed-* 2>/dev/null | head -1)"
  assert_file_exists "$proposed" "proposed file should be computed even without a project-specific nvim match" || return 1
  rm -rf "$hook_tmpdir"
}

# ── Run all tests ────────────────────────────────────────────────

run_test "Hook works after Neovim restart (stale socket)" test_stale_socket_recovery
run_test "Hook exits cleanly without a guaranteed project match" test_no_matching_project_nvim_graceful

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
