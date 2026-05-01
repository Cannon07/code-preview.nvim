#!/usr/bin/env bash
# test_apply_patch.sh — E2E tests for Codex CLI apply_patch workflow
#
# Codex carries the `*** Begin Patch … *** End Patch` payload in
# tool_input.command (not tool_input.patch_text). The adapter rewrites the
# field name and forwards to bin/core-pre-tool.sh, which uses the same
# apply-patch.lua parser the other backends share.

CODEX_PRE="$REPO_ROOT/backends/codex/code-preview-diff.sh"
CODEX_POST="$REPO_ROOT/backends/codex/code-close-diff.sh"

# Build a Codex apply_patch payload — patch text lives in tool_input.command.
run_codex_pre_patch() {
  local patch_text="$1"
  local payload
  payload=$(jq -n \
    --arg cwd "$TEST_PROJECT_DIR" \
    --arg pt  "$patch_text" \
    '{tool_name:"apply_patch", cwd:$cwd, tool_input:{command:$pt}}')
  echo "$payload" | \
    NVIM_LISTEN_ADDRESS="$TEST_SOCKET" \
    bash "$CODEX_PRE" 2>/dev/null || true
}

run_codex_post_patch() {
  local patch_text="$1"
  local payload
  payload=$(jq -n \
    --arg cwd "$TEST_PROJECT_DIR" \
    --arg pt  "$patch_text" \
    '{tool_name:"apply_patch", cwd:$cwd, tool_input:{command:$pt}}')
  echo "$payload" | \
    NVIM_LISTEN_ADDRESS="$TEST_SOCKET" \
    bash "$CODEX_POST" 2>/dev/null || true
}

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

# ── Test: single-file Update via apply_patch ────────────────────

test_codex_apply_patch_update() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "hello.txt" "line one
line two
line three")"

  local patch
  patch=$(printf '%s\n' \
    "*** Begin Patch" \
    "*** Update File: hello.txt" \
    "@@" \
    " line one" \
    "-line two" \
    "+line two modified" \
    " line three" \
    "*** End Patch")

  run_codex_pre_patch "$patch"
  sleep 0.5

  assert_eq "true" "$(nvim_eval "require('code-preview.diff').is_open()")" \
    "diff should open after apply_patch update" || return 1
  assert_eq "modified" "$(nvim_eval "require('code-preview.changes').get('$test_file')")" \
    "Update File should mark target as modified" || return 1

  run_codex_post_patch "$patch"
  sleep 0.5

  assert_eq "false" "$(nvim_eval "require('code-preview.diff').is_open()")" \
    "diff should close after Update File post" || return 1
}

# ── Test: Add File marks new file as created ────────────────────

test_codex_apply_patch_add() {
  reset_test_state
  local new_file="$TEST_PROJECT_DIR/src/cx_added.lua"

  local patch
  patch=$(printf '%s\n' \
    "*** Begin Patch" \
    "*** Add File: src/cx_added.lua" \
    "+local M = {}" \
    "+return M" \
    "*** End Patch")

  run_codex_pre_patch "$patch"
  sleep 0.5

  assert_eq "created" "$(nvim_eval "require('code-preview.changes').get('$new_file')")" \
    "Add File should mark target as created" || return 1

  run_codex_post_patch "$patch"
  sleep 0.5

  assert_eq "false" "$(nvim_eval "require('code-preview.diff').is_open()")" \
    "diff should close after Add File post" || return 1
  assert_eq "0" "$(nvim_eval "vim.tbl_count(require('code-preview.changes').get_all())")" \
    "registry should be empty after Add File cycle" || return 1
}

# ── Test: mixed Update+Add+Delete — all open, all close ─────────

# Mirrors tests/backends/copilot/test_apply_patch.sh — locks the contract
# that the post-hook closes diffs for every directive in the patch, not
# just the first one.
test_codex_apply_patch_mixed() {
  reset_test_state

  local f_update f_delete1 f_delete2 f_add
  f_update="$(create_test_file  "README.md"  "existing line
old text
tail")"
  f_delete1="$(create_test_file "old1.txt"   "bye1")"
  f_delete2="$(create_test_file "old2.txt"   "bye2")"
  f_add="$TEST_PROJECT_DIR/brand_new.txt"

  local patch
  patch=$(printf '%s\n' \
    "*** Begin Patch" \
    "*** Update File: README.md" \
    "@@" \
    " existing line" \
    "-old text" \
    "+new text" \
    " tail" \
    "*** Add File: brand_new.txt" \
    "+hello from new file" \
    "*** Delete File: old1.txt" \
    "*** Delete File: old2.txt" \
    "*** End Patch")

  run_codex_pre_patch "$patch"
  sleep 0.6

  assert_eq "4" "$(nvim_eval "vim.tbl_count(require('code-preview.changes').get_all())")" \
    "4 files should be tracked after pre-hook" || return 1

  assert_eq "modified" "$(nvim_eval "require('code-preview.changes').get('$f_update')")" \
    "Update File should be modified" || return 1
  assert_eq "created"  "$(nvim_eval "require('code-preview.changes').get('$f_add')")" \
    "Add File should be created" || return 1

  assert_eq "true" "$(nvim_eval "require('code-preview.diff').is_open()")" \
    "diff should be open during mixed patch" || return 1

  run_codex_post_patch "$patch"
  sleep 0.6

  assert_eq "false" "$(nvim_eval "require('code-preview.diff').is_open()")" \
    "all diffs should close after post-hook" || return 1
  assert_eq "0" "$(nvim_eval "vim.tbl_count(require('code-preview.changes').get_all())")" \
    "registry should be empty after mixed-patch post" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "Codex apply_patch Update File opens and closes diff"     test_codex_apply_patch_update
run_test "Codex apply_patch Add File marks as created"             test_codex_apply_patch_add
run_test "Codex apply_patch mixed Update+Add+Delete closes all"    test_codex_apply_patch_mixed

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
