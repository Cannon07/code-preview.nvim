#!/usr/bin/env bash
# test_edit.sh — E2E tests for OpenCode plugin edit workflows
#
# Tests the TypeScript plugin by invoking it directly with mock data,
# then verifying Neovim state via RPC.

# ── Check for tsx/bun ────────────────────────────────────────────

_OPENCODE_RUNNER=""
if command -v bun >/dev/null 2>&1; then
  _OPENCODE_RUNNER="bun"
elif command -v npx >/dev/null 2>&1; then
  _OPENCODE_RUNNER="npx tsx"
else
  echo -e "${YELLOW}  ⊘ Skipping OpenCode tests (neither bun nor npx found)${NC}"
  return 0 2>/dev/null || exit 0
fi

HARNESS="$SCRIPT_DIR/backends/opencode/harness.ts"

# Helper to run the harness
run_opencode() {
  NVIM_LISTEN_ADDRESS="$TEST_SOCKET" $_OPENCODE_RUNNER "$HARNESS" "$@" 2>/dev/null
}

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

# ── Test: OpenCode edit before/after ─────────────────────────────

test_opencode_edit() {
  local test_file
  test_file="$(create_test_file "src/oc_edit.lua" 'local x = 1')"

  local output
  output="$(run_opencode edit_before "$TEST_SOCKET" "$TEST_PROJECT_DIR" "$test_file" "local x = 1" "local x = 99")"

  if [[ "$output" != *"OK"* ]]; then
    echo -e "  ${RED}harness returned: $output${NC}" >&2
    return 1
  fi

  sleep 0.5

  local is_open
  is_open="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "diff should be open after OpenCode edit_before" || return 1

  local change_status
  change_status="$(nvim_eval "require('claude-preview.changes').get('$test_file')")"
  assert_eq "modified" "$change_status" "file should be marked as modified" || return 1

  # Close via after hook
  output="$(run_opencode edit_after "$TEST_SOCKET" "$TEST_PROJECT_DIR" "$test_file")"
  sleep 0.5

  local is_open_after
  is_open_after="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "false" "$is_open_after" "diff should be closed after edit_after" || return 1

  local changes_count
  changes_count="$(nvim_eval "vim.tbl_count(require('claude-preview.changes').get_all())")"
  assert_eq "0" "$changes_count" "changes should be cleared" || return 1
}

# ── Test: OpenCode write (new file) ──────────────────────────────

test_opencode_write_new() {
  local new_file="$TEST_PROJECT_DIR/src/oc_new.lua"

  local output
  output="$(run_opencode write_before "$TEST_SOCKET" "$TEST_PROJECT_DIR" "$new_file" "local M = {} return M")"

  if [[ "$output" != *"OK"* ]]; then
    echo -e "  ${RED}harness returned: $output${NC}" >&2
    return 1
  fi

  sleep 0.5

  local is_open
  is_open="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "diff should be open for OpenCode write" || return 1

  local change_status
  change_status="$(nvim_eval "require('claude-preview.changes').get('$new_file')")"
  assert_eq "created" "$change_status" "new file should be marked as created" || return 1

  run_opencode write_after "$TEST_SOCKET" "$TEST_PROJECT_DIR" "$new_file" >/dev/null 2>&1
  sleep 0.5
}

# ── Test: OpenCode bash rm detection ─────────────────────────────

test_opencode_bash_rm() {
  local test_file
  test_file="$(create_test_file "oc_delete_me.txt" 'goodbye')"

  local output
  output="$(run_opencode bash_before "$TEST_SOCKET" "$TEST_PROJECT_DIR" "rm $test_file")"

  if [[ "$output" != *"OK"* ]]; then
    echo -e "  ${RED}harness returned: $output${NC}" >&2
    return 1
  fi

  sleep 0.5

  local change_status
  change_status="$(nvim_eval "require('claude-preview.changes').get('$test_file')")"
  assert_eq "deleted" "$change_status" "rm target should be marked as deleted" || return 1

  run_opencode bash_after "$TEST_SOCKET" "$TEST_PROJECT_DIR" >/dev/null 2>&1
  sleep 0.5

  local change_after
  change_after="$(nvim_eval "require('claude-preview.changes').get('$test_file') or 'nil'")"
  assert_eq "nil" "$change_after" "deletion marker should be cleared" || return 1
}

# ── Test: OpenCode relative path resolution ──────────────────────

test_opencode_relative_path() {
  local test_file
  test_file="$(create_test_file "src/relative.lua" 'local r = 1')"

  # Pass relative path — the plugin should resolve it against projectCwd
  local output
  output="$(run_opencode edit_before "$TEST_SOCKET" "$TEST_PROJECT_DIR" "src/relative.lua" "local r = 1" "local r = 2")"

  if [[ "$output" != *"OK"* ]]; then
    echo -e "  ${RED}harness returned: $output${NC}" >&2
    return 1
  fi

  sleep 0.5

  local is_open
  is_open="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "diff should open with relative path" || return 1

  run_opencode edit_after "$TEST_SOCKET" "$TEST_PROJECT_DIR" "src/relative.lua" >/dev/null 2>&1
  sleep 0.5
}

# ── Run all tests ────────────────────────────────────────────────

run_test "OpenCode edit before/after opens and closes diff" test_opencode_edit
run_test "OpenCode write (new file) marks as created" test_opencode_write_new
run_test "OpenCode bash rm marks as deleted" test_opencode_bash_rm
run_test "OpenCode resolves relative file paths" test_opencode_relative_path

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
