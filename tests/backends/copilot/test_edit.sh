#!/usr/bin/env bash
# test_edit.sh — E2E tests for GitHub Copilot CLI edit/create/bash workflows
#
# Drives Copilot's native hook payload shape ({toolName, cwd, toolArgs}) through
# backends/copilot/code-preview-diff.sh (pre) and code-close-diff.sh (post),
# then verifies Neovim state via RPC.
#
# Copilot quirk: toolArgs is a stringified JSON object for most tools, and the
# raw patch text for apply_patch. The adapter normalizes both to the shared
# {tool_name, cwd, tool_input} format consumed by bin/core-pre-tool.sh.

COPILOT_PRE="$REPO_ROOT/backends/copilot/code-preview-diff.sh"
COPILOT_POST="$REPO_ROOT/backends/copilot/code-close-diff.sh"

# Feed a Copilot-shaped payload to the pre-tool adapter.
#   $1 = toolName, $2 = toolArgs (JSON-encoded string OR raw text for apply_patch)
run_copilot_pre() {
  local tool_name="$1"
  local tool_args="$2"
  local payload
  payload=$(jq -n \
    --arg tn "$tool_name" \
    --arg cwd "$TEST_PROJECT_DIR" \
    --arg ta "$tool_args" \
    '{toolName:$tn, cwd:$cwd, toolArgs:$ta}')
  echo "$payload" | \
    NVIM_LISTEN_ADDRESS="$TEST_SOCKET" \
    bash "$COPILOT_PRE" 2>/dev/null || true
}

run_copilot_post() {
  local tool_name="$1"
  local tool_args="$2"
  local payload
  payload=$(jq -n \
    --arg tn "$tool_name" \
    --arg cwd "$TEST_PROJECT_DIR" \
    --arg ta "$tool_args" \
    '{toolName:$tn, cwd:$cwd, toolArgs:$ta}')
  echo "$payload" | \
    NVIM_LISTEN_ADDRESS="$TEST_SOCKET" \
    bash "$COPILOT_POST" 2>/dev/null || true
}

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

# ── Test: edit tool opens diff, post closes it ──────────────────

test_copilot_edit() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "src/cp_edit.lua" 'local x = 1')"

  local tool_args
  tool_args=$(jq -nc \
    --arg p "$test_file" \
    --arg o "local x = 1" \
    --arg n "local x = 99" \
    '{path:$p, old_str:$o, new_str:$n}')

  run_copilot_pre "edit" "$tool_args"
  sleep 0.5

  local is_open
  is_open="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "diff should open after Copilot edit" || return 1

  local change_status
  change_status="$(nvim_eval "require('code-preview.changes').get('$test_file')")"
  assert_eq "modified" "$change_status" "file should be marked as modified" || return 1

  run_copilot_post "edit" "$tool_args"
  sleep 0.5

  local is_open_after
  is_open_after="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "false" "$is_open_after" "diff should close after post-hook" || return 1
}

# ── Test: str_replace is aliased to edit ────────────────────────

# Some Copilot models emit `str_replace` instead of `edit` for the same
# {path, old_str, new_str} shape. The adapter must normalize both to Edit
# so they share the lifecycle. This test locks the alias contract.
test_copilot_str_replace_alias() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "src/cp_sr.lua" 'local y = 1')"

  local tool_args
  tool_args=$(jq -nc \
    --arg p "$test_file" \
    --arg o "local y = 1" \
    --arg n "local y = 2" \
    '{path:$p, old_str:$o, new_str:$n}')

  run_copilot_pre "str_replace" "$tool_args"
  sleep 0.5

  local is_open
  is_open="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "str_replace should open a diff (aliased to Edit)" || return 1

  local change_status
  change_status="$(nvim_eval "require('code-preview.changes').get('$test_file')")"
  assert_eq "modified" "$change_status" "str_replace should mark file as modified" || return 1

  run_copilot_post "str_replace" "$tool_args"
  sleep 0.5

  local is_open_after
  is_open_after="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "false" "$is_open_after" "str_replace post-hook should close diff" || return 1
}

# ── Test: create tool marks new file as created ─────────────────

test_copilot_create() {
  reset_test_state
  local new_file="$TEST_PROJECT_DIR/src/cp_new.lua"

  local tool_args
  tool_args=$(jq -nc \
    --arg p "$new_file" \
    --arg c "local M = {}
return M" \
    '{path:$p, file_text:$c}')

  run_copilot_pre "create" "$tool_args"
  sleep 0.5

  local is_open
  is_open="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "diff should open for Copilot create" || return 1

  local change_status
  change_status="$(nvim_eval "require('code-preview.changes').get('$new_file')")"
  assert_eq "created" "$change_status" "new file should be marked as created" || return 1

  run_copilot_post "create" "$tool_args"
  sleep 0.5

  local is_open_after
  is_open_after="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "false" "$is_open_after" "diff should close after create post-hook" || return 1

  local changes_count
  changes_count="$(nvim_eval "vim.tbl_count(require('code-preview.changes').get_all())")"
  assert_eq "0" "$changes_count" "changes registry should be empty after create cycle" || return 1
}

# ── Test: bash rm marks target as deleted ───────────────────────

test_copilot_bash_rm() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "cp_delete_me.txt" 'goodbye')"

  local tool_args
  tool_args=$(jq -nc \
    --arg cmd "rm $test_file" \
    --arg d "delete temp file" \
    '{command:$cmd, description:$d}')

  run_copilot_pre "bash" "$tool_args"
  sleep 0.5

  local change_status
  change_status="$(nvim_eval "require('code-preview.changes').get('$test_file')")"
  assert_eq "deleted" "$change_status" "rm target should be marked as deleted" || return 1

  run_copilot_post "bash" "$tool_args"
  sleep 0.5

  local change_after
  change_after="$(nvim_eval "require('code-preview.changes').get('$test_file') or 'nil'")"
  assert_eq "nil" "$change_after" "deletion marker should be cleared" || return 1
}

# ── Test: relative path resolves against cwd ────────────────────

test_copilot_relative_path() {
  reset_test_state
  create_test_file "src/cp_rel.lua" 'local r = 1' >/dev/null
  local abs_file="$TEST_PROJECT_DIR/src/cp_rel.lua"

  # Pass a relative path in toolArgs — adapter should resolve against cwd
  local tool_args
  tool_args=$(jq -nc \
    --arg p "src/cp_rel.lua" \
    --arg o "local r = 1" \
    --arg n "local r = 2" \
    '{path:$p, old_str:$o, new_str:$n}')

  run_copilot_pre "edit" "$tool_args"
  sleep 0.5

  local is_open
  is_open="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "diff should open from relative path" || return 1

  # The absolute form is what ends up in the changes registry
  local change_status
  change_status="$(nvim_eval "require('code-preview.changes').get('$abs_file')")"
  assert_eq "modified" "$change_status" "relative path should resolve to absolute" || return 1

  run_copilot_post "edit" "$tool_args"
  sleep 0.5
}

# ── Test: noise tools exit without opening a diff ───────────────

test_copilot_noise_tools_ignored() {
  reset_test_state

  # view, glob, report_intent etc. must not trigger a diff preview.
  run_copilot_pre "view"          '{"path":"/tmp/whatever"}'
  run_copilot_pre "report_intent" '{"intent":"just looking"}'
  run_copilot_pre "glob"          '{"pattern":"**/*.lua"}'
  sleep 0.3

  local is_open
  is_open="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "false" "$is_open" "noise tools should not open a diff" || return 1

  local changes_count
  changes_count="$(nvim_eval "vim.tbl_count(require('code-preview.changes').get_all())")"
  assert_eq "0" "$changes_count" "noise tools should not mark changes" || return 1
}

# ── Test: malformed payloads skip cleanly (no broken diff) ──────

# If Copilot ever sends an edit/create/bash with missing toolArgs fields,
# the adapter must exit 0 rather than push an empty-path diff downstream.
# Regression guard for the stdin-dispatch foot-gun.
test_copilot_malformed_payloads_skip() {
  reset_test_state

  # edit with empty path
  run_copilot_pre "edit"   '{"old_str":"a","new_str":"b"}'
  # create with missing path
  run_copilot_pre "create" '{"file_text":"hello"}'
  # bash with empty command
  run_copilot_pre "bash"   '{"description":"noop"}'
  # toolArgs entirely absent on a non-noise tool
  local payload
  payload=$(jq -n --arg cwd "$TEST_PROJECT_DIR" '{toolName:"edit", cwd:$cwd}')
  echo "$payload" | \
    NVIM_LISTEN_ADDRESS="$TEST_SOCKET" \
    bash "$COPILOT_PRE" 2>/dev/null || true

  sleep 0.3

  local is_open
  is_open="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "false" "$is_open" "malformed payloads should not open a diff" || return 1

  local changes_count
  changes_count="$(nvim_eval "vim.tbl_count(require('code-preview.changes').get_all())")"
  assert_eq "0" "$changes_count" "malformed payloads should not mark changes" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "Copilot edit opens and closes diff"          test_copilot_edit
run_test "Copilot str_replace aliases to edit"         test_copilot_str_replace_alias
run_test "Copilot create marks new file as created"    test_copilot_create
run_test "Copilot bash rm marks target as deleted"     test_copilot_bash_rm
run_test "Copilot resolves relative file paths"        test_copilot_relative_path
run_test "Copilot noise tools (view/glob/etc) ignored" test_copilot_noise_tools_ignored
run_test "Copilot malformed payloads skip cleanly"     test_copilot_malformed_payloads_skip

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
