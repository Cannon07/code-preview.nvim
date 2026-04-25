#!/usr/bin/env bash
# test_apply_patch.sh — E2E tests for Copilot CLI apply_patch workflow
#
# Drives the full pipeline for GPT-style apply_patch tool calls:
#   raw patch text as toolArgs → backends/copilot/code-preview-diff.sh
#     → bin/core-pre-tool.sh → bin/apply-patch.lua
#     → Neovim diff previews for all files in the patch
# And the mirror post path:
#   → backends/copilot/code-close-diff.sh
#     → bin/core-post-tool.sh
#     → close_for_file for every Update/Add/Delete directive.
#
# Distinct from tests/backends/opencode/test_apply_patch.sh, which exercises
# only bin/apply-patch.lua in isolation (parser-level).

COPILOT_PRE="$REPO_ROOT/backends/copilot/code-preview-diff.sh"
COPILOT_POST="$REPO_ROOT/backends/copilot/code-close-diff.sh"

# apply_patch's toolArgs is the raw patch text, not a JSON object. jq will
# still encode it as a JSON string when we build the outer payload, and the
# adapter's `if type == "string"` branch passes it through untouched.
run_copilot_pre_patch() {
  local patch_text="$1"
  local payload
  payload=$(jq -n \
    --arg cwd "$TEST_PROJECT_DIR" \
    --arg ta "$patch_text" \
    '{toolName:"apply_patch", cwd:$cwd, toolArgs:$ta}')
  echo "$payload" | \
    NVIM_LISTEN_ADDRESS="$TEST_SOCKET" \
    bash "$COPILOT_PRE" 2>/dev/null || true
}

run_copilot_post_patch() {
  local patch_text="$1"
  local payload
  payload=$(jq -n \
    --arg cwd "$TEST_PROJECT_DIR" \
    --arg ta "$patch_text" \
    '{toolName:"apply_patch", cwd:$cwd, toolArgs:$ta}')
  echo "$payload" | \
    NVIM_LISTEN_ADDRESS="$TEST_SOCKET" \
    bash "$COPILOT_POST" 2>/dev/null || true
}

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

# ── Test: single-file update via apply_patch ────────────────────

test_copilot_apply_patch_update() {
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

  run_copilot_pre_patch "$patch"
  sleep 0.5

  local is_open
  is_open="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "diff should open after apply_patch update" || return 1

  local change_status
  change_status="$(nvim_eval "require('code-preview.changes').get('$test_file')")"
  assert_eq "modified" "$change_status" "file should be marked as modified" || return 1

  run_copilot_post_patch "$patch"
  sleep 0.5

  local is_open_after
  is_open_after="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "false" "$is_open_after" "diff should close after post-hook" || return 1
}

# ── Test: apply_patch with Add File marks as created ────────────

test_copilot_apply_patch_add() {
  reset_test_state
  local new_file="$TEST_PROJECT_DIR/src/new.lua"

  local patch
  patch=$(printf '%s\n' \
    "*** Begin Patch" \
    "*** Add File: src/new.lua" \
    "+local M = {}" \
    "+return M" \
    "*** End Patch")

  run_copilot_pre_patch "$patch"
  sleep 0.5

  local change_status
  change_status="$(nvim_eval "require('code-preview.changes').get('$new_file')")"
  assert_eq "created" "$change_status" "Add File should mark as created" || return 1

  run_copilot_post_patch "$patch"
  sleep 0.5

  local is_open_after
  is_open_after="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "false" "$is_open_after" "diff should close after Add File post-hook" || return 1

  local changes_count
  changes_count="$(nvim_eval "vim.tbl_count(require('code-preview.changes').get_all())")"
  assert_eq "0" "$changes_count" "changes registry should be empty after Add File cycle" || return 1
}

# ── Test: mixed Update+Add+Delete — all open, all close ─────────

# This is the integration-level twin of tests/core/test_post_tool_patch_paths.sh.
# The core test stubs close_for_file; here we drive the full pipeline and
# confirm the real diff/changes state lines up end-to-end.
test_copilot_apply_patch_mixed() {
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

  run_copilot_pre_patch "$patch"
  sleep 0.6

  # All four files should appear in the changes registry.
  local changes_count
  changes_count="$(nvim_eval "vim.tbl_count(require('code-preview.changes').get_all())")"
  assert_eq "4" "$changes_count" "4 files should be tracked after pre-hook" || return 1

  # Registry status per file type.
  assert_eq "modified" "$(nvim_eval "require('code-preview.changes').get('$f_update')")"  \
    "Update File should be modified" || return 1
  assert_eq "created"  "$(nvim_eval "require('code-preview.changes').get('$f_add')")"     \
    "Add File should be created" || return 1

  # A diff should be open.
  assert_eq "true" "$(nvim_eval "require('code-preview.diff').is_open()")" \
    "diff should be open during mixed patch" || return 1

  # Post-hook must close ALL four — the regression fixed in bin/core-post-tool.sh.
  run_copilot_post_patch "$patch"
  sleep 0.6

  local is_open_after
  is_open_after="$(nvim_eval "require('code-preview.diff').is_open()")"
  assert_eq "false" "$is_open_after" "all diffs should close after post-hook" || return 1

  local changes_after
  changes_after="$(nvim_eval "vim.tbl_count(require('code-preview.changes').get_all())")"
  assert_eq "0" "$changes_after" "changes registry should be empty after post-hook" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "Copilot apply_patch Update File opens and closes diff" test_copilot_apply_patch_update
run_test "Copilot apply_patch Add File marks as created"         test_copilot_apply_patch_add
run_test "Copilot apply_patch mixed Update+Add+Delete closes all" test_copilot_apply_patch_mixed

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
