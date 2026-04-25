#!/usr/bin/env bash
# test_post_tool_patch_paths.sh — Regression test for bin/core-post-tool.sh
#
# Verifies that the patch-path extractor for ApplyPatch calls close_for_file
# for every file referenced in the patch — Update, Add, AND Delete.
#
# Regression: Delete File: directives were previously skipped by the extractor
# regex, leaving delete-diff tabs lingering after accept.

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

# Install a stub close_for_file that records every path it's called with into
# a global table. We don't care about actual diff lifecycle here — just that
# the hook script extracted the right paths from the patch.
install_stub() {
  nvim_exec "
    _G.__closed_paths = {}
    package.loaded['code-preview.diff'] = package.loaded['code-preview.diff'] or {}
    package.loaded['code-preview.diff'].close_for_file = function(p)
      table.insert(_G.__closed_paths, p)
    end
  "
}

reset_stub() {
  nvim_exec "_G.__closed_paths = {}"
}

closed_paths_json() {
  nvim_eval "vim.json.encode(_G.__closed_paths or {})"
}

# Feed a normalized ApplyPatch JSON payload to core-post-tool.sh
run_post_apply_patch() {
  local patch_text="$1"
  local payload
  payload=$(jq -n \
    --arg cwd "$TEST_PROJECT_DIR" \
    --arg patch "$patch_text" \
    '{tool_name:"ApplyPatch", cwd:$cwd, tool_input:{patch_text:$patch}}')
  echo "$payload" | \
    NVIM_LISTEN_ADDRESS="$TEST_SOCKET" \
    bash "$REPO_ROOT/bin/core-post-tool.sh" 2>/dev/null || true
  # Give nvim time to process async RPC
  sleep 0.3
}

# ── Test: Delete File directive triggers close_for_file ──────────

test_delete_file_closes_diff() {
  install_stub
  reset_stub

  local patch
  patch=$(printf '%s\n' \
    "*** Begin Patch" \
    "*** Delete File: to_remove.txt" \
    "*** End Patch")

  run_post_apply_patch "$patch"

  local closed
  closed="$(closed_paths_json)"
  assert_contains "$closed" "to_remove.txt" "Delete File path should be passed to close_for_file" || return 1
}

# ── Test: Mixed Update + Add + Delete all close ──────────────────

test_mixed_patch_closes_all_diffs() {
  install_stub
  reset_stub

  local patch
  patch=$(printf '%s\n' \
    "*** Begin Patch" \
    "*** Update File: README.md" \
    "@@" \
    " existing line" \
    "-old text" \
    "+new text" \
    "*** Add File: src/new.lua" \
    "@@" \
    "+local M = {}" \
    "+return M" \
    "*** Delete File: old.txt" \
    "*** End Patch")

  run_post_apply_patch "$patch"

  local closed
  closed="$(closed_paths_json)"
  assert_contains "$closed" "README.md"     "Update File path should be closed" || return 1
  assert_contains "$closed" "src/new.lua"   "Add File path should be closed" || return 1
  assert_contains "$closed" "old.txt"       "Delete File path should be closed" || return 1

  # Confirm exactly three paths were closed — no duplicates, no drops.
  local count
  count="$(nvim_eval "#(_G.__closed_paths or {})")"
  assert_eq "3" "$count" "should close exactly 3 paths for 3-file patch" || return 1
}

# ── Test: Update-only patch (sanity — pre-existing behavior) ─────

test_update_only_closes_diff() {
  install_stub
  reset_stub

  local patch
  patch=$(printf '%s\n' \
    "*** Begin Patch" \
    "*** Update File: a.txt" \
    "@@" \
    " ctx" \
    "-x" \
    "+y" \
    "*** End Patch")

  run_post_apply_patch "$patch"

  local closed
  closed="$(closed_paths_json)"
  assert_contains "$closed" "a.txt" "Update File path should be closed" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "core-post-tool.sh closes diff for Delete File directive" test_delete_file_closes_diff
run_test "core-post-tool.sh closes diffs for mixed Update+Add+Delete patch" test_mixed_patch_closes_all_diffs
run_test "core-post-tool.sh closes diff for Update File directive" test_update_only_closes_diff

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
