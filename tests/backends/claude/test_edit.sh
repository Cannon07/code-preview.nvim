#!/usr/bin/env bash
# test_edit.sh — E2E tests for Claude Code Edit/Write/MultiEdit workflows
#
# Tests the full pipeline:
#   JSON payload → claude-preview-diff.sh → RPC → Neovim state
#   JSON payload → claude-close-diff.sh  → RPC → cleanup

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

# ── Test: Edit tool opens diff preview ───────────────────────────

test_edit_opens_diff() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "src/hello.lua" 'print("hello world")')"

  local payload
  payload=$(cat <<EOF
{
  "tool_name": "Edit",
  "cwd": "$TEST_PROJECT_DIR",
  "tool_input": {
    "file_path": "$test_file",
    "old_string": "hello world",
    "new_string": "hello universe",
    "replace_all": false
  }
}
EOF
)

  local output
  output="$(run_pretool_hook "$payload")"

  # Default config (defer_claude_permissions=false) returns "ask" when nvim is running
  local expected='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Diff preview sent to Neovim. Review before accepting."}}'
  assert_eq "$expected" "$output" "PreToolUse should return permissionDecision ask" || return 1

  # Give Neovim a moment to process the RPC
  sleep 0.5

  # Diff tab should be open
  local is_open
  is_open="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "diff should be open after Edit PreToolUse" || return 1

  # Changes registry should have the file marked as modified
  local change_status
  change_status="$(nvim_eval "require('claude-preview.changes').get('$test_file')")"
  assert_eq "modified" "$change_status" "file should be marked as modified" || return 1

  # Proposed temp file should contain the edit result
  local proposed="${TMPDIR:-/tmp}/claude-diff-proposed"
  assert_file_exists "$proposed" "proposed temp file should exist" || return 1
  local proposed_content
  proposed_content="$(cat "$proposed")"
  assert_contains "$proposed_content" "hello universe" "proposed file should contain the edit" || return 1

  # Close the diff via PostToolUse
  run_posttool_hook "$payload"
  sleep 0.5

  local is_open_after
  is_open_after="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "false" "$is_open_after" "diff should be closed after PostToolUse" || return 1

  # Changes should be cleared
  local changes_after
  changes_after="$(nvim_eval "vim.tbl_count(require('claude-preview.changes').get_all())")"
  assert_eq "0" "$changes_after" "changes should be cleared after PostToolUse" || return 1
}

# ── Test: Write tool (new file) opens diff ───────────────────────

test_write_new_file() {
  reset_test_state
  local new_file="$TEST_PROJECT_DIR/src/new_module.lua"

  local payload
  payload=$(cat <<EOF
{
  "tool_name": "Write",
  "cwd": "$TEST_PROJECT_DIR",
  "tool_input": {
    "file_path": "$new_file",
    "content": "local M = {}\nfunction M.greet() return 'hi' end\nreturn M"
  }
}
EOF
)

  local output
  output="$(run_pretool_hook "$payload")"
  local expected='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Diff preview sent to Neovim. Review before accepting."}}'
  assert_eq "$expected" "$output" || return 1

  sleep 0.5

  local is_open
  is_open="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "diff should be open for Write tool" || return 1

  # New file should be marked as "created" (file doesn't exist on disk)
  local change_status
  change_status="$(nvim_eval "require('claude-preview.changes').get('$new_file')")"
  assert_eq "created" "$change_status" "new file should be marked as created" || return 1

  # Close
  run_posttool_hook "$payload"
  sleep 0.5

  local is_open_after
  is_open_after="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "false" "$is_open_after" "diff should be closed" || return 1
}

# ── Test: Write tool (existing file) opens diff ─────────────────

test_write_existing_file() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "config.json" '{"key": "old_value"}')"

  local payload
  payload=$(cat <<EOF
{
  "tool_name": "Write",
  "cwd": "$TEST_PROJECT_DIR",
  "tool_input": {
    "file_path": "$test_file",
    "content": "{\"key\": \"new_value\", \"extra\": true}"
  }
}
EOF
)

  local output
  output="$(run_pretool_hook "$payload")"
  local expected='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Diff preview sent to Neovim. Review before accepting."}}'
  assert_eq "$expected" "$output" || return 1

  sleep 0.5

  local change_status
  change_status="$(nvim_eval "require('claude-preview.changes').get('$test_file')")"
  assert_eq "modified" "$change_status" "existing file should be marked as modified" || return 1

  run_posttool_hook "$payload" >/dev/null
  sleep 0.5
}


# ── Test: Bash rm detection marks files as deleted ───────────────

test_bash_rm_detection() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "to_delete.txt" 'this will be deleted')"

  local payload
  payload=$(cat <<EOF
{
  "tool_name": "Bash",
  "cwd": "$TEST_PROJECT_DIR",
  "tool_input": {
    "command": "rm $test_file"
  }
}
EOF
)

  run_pretool_hook "$payload" >/dev/null
  sleep 0.5

  # File should be marked as deleted in changes registry
  local change_status
  change_status="$(nvim_eval "require('claude-preview.changes').get('$test_file')")"
  assert_eq "deleted" "$change_status" "rm target should be marked as deleted" || return 1

  # PostToolUse for Bash should clear deletion markers only
  run_posttool_hook "$payload" >/dev/null
  sleep 0.5

  local change_after
  change_after="$(nvim_eval "require('claude-preview.changes').get('$test_file') or 'nil'")"
  assert_eq "nil" "$change_after" "deletion marker should be cleared after PostToolUse" || return 1
}

# ── Test: Non-rm Bash command is ignored ─────────────────────────

test_bash_non_rm_passthrough() {
  reset_test_state
  local payload
  payload=$(cat <<EOF
{
  "tool_name": "Bash",
  "cwd": "$TEST_PROJECT_DIR",
  "tool_input": {
    "command": "echo hello"
  }
}
EOF
)

  # Should exit cleanly without opening a diff or setting changes
  run_pretool_hook "$payload" >/dev/null
  sleep 0.3

  local changes_count
  changes_count="$(nvim_eval "vim.tbl_count(require('claude-preview.changes').get_all())")"
  assert_eq "0" "$changes_count" "non-rm bash should not set any changes" || return 1
}

# ── Test: Unknown tool is ignored ────────────────────────────────

test_unknown_tool_passthrough() {
  reset_test_state
  local payload
  payload=$(cat <<EOF
{
  "tool_name": "Read",
  "cwd": "$TEST_PROJECT_DIR",
  "tool_input": {
    "file_path": "/some/file.txt"
  }
}
EOF
)

  local output
  output="$(run_pretool_hook "$payload")"
  # Should produce no output (exit 0 silently)
  assert_eq "" "$output" "unknown tool should produce no output" || return 1
}

# ── Test: Edit with replace_all ──────────────────────────────────

test_edit_replace_all() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "src/replace_all.txt" 'foo bar foo baz foo')"

  local payload
  payload=$(cat <<EOF
{
  "tool_name": "Edit",
  "cwd": "$TEST_PROJECT_DIR",
  "tool_input": {
    "file_path": "$test_file",
    "old_string": "foo",
    "new_string": "qux",
    "replace_all": true
  }
}
EOF
)

  run_pretool_hook "$payload" >/dev/null
  sleep 0.5

  local proposed="${TMPDIR:-/tmp}/claude-diff-proposed"
  local proposed_content
  proposed_content="$(cat "$proposed")"
  assert_not_contains "$proposed_content" "foo" "all occurrences of 'foo' should be replaced" || return 1
  assert_contains "$proposed_content" "qux bar qux baz qux" "all should be replaced with 'qux'" || return 1

  run_posttool_hook "$payload" >/dev/null
  sleep 0.3
}

# ── Test: Diff reopens correctly (sequential edits) ──────────────

test_sequential_edits() {
  reset_test_state
  local file1
  file1="$(create_test_file "src/file1.lua" 'local x = 1')"
  local file2
  file2="$(create_test_file "src/file2.lua" 'local y = 2')"

  # First edit
  local payload1
  payload1=$(cat <<EOF
{
  "tool_name": "Edit",
  "cwd": "$TEST_PROJECT_DIR",
  "tool_input": {
    "file_path": "$file1",
    "old_string": "local x = 1",
    "new_string": "local x = 100"
  }
}
EOF
)

  run_pretool_hook "$payload1" >/dev/null
  sleep 0.5
  local is_open1
  is_open1="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "true" "$is_open1" "first diff should be open" || return 1

  run_posttool_hook "$payload1" >/dev/null
  sleep 0.5

  # Second edit (different file)
  local payload2
  payload2=$(cat <<EOF
{
  "tool_name": "Edit",
  "cwd": "$TEST_PROJECT_DIR",
  "tool_input": {
    "file_path": "$file2",
    "old_string": "local y = 2",
    "new_string": "local y = 200"
  }
}
EOF
)

  run_pretool_hook "$payload2" >/dev/null
  sleep 0.5
  local is_open2
  is_open2="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "true" "$is_open2" "second diff should be open" || return 1

  run_posttool_hook "$payload2" >/dev/null
  sleep 0.5

  local is_open_final
  is_open_final="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "false" "$is_open_final" "diff should be closed after both edits" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "Edit tool opens diff and PostToolUse closes it" test_edit_opens_diff
run_test "Write tool (new file) marks as created" test_write_new_file
run_test "Write tool (existing file) marks as modified" test_write_existing_file
run_test "Bash rm detection marks files as deleted" test_bash_rm_detection
run_test "Non-rm Bash command is ignored" test_bash_non_rm_passthrough
run_test "Unknown tool is silently ignored" test_unknown_tool_passthrough
run_test "Edit with replace_all replaces all occurrences" test_edit_replace_all
run_test "Sequential edits open/close diff correctly" test_sequential_edits

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
