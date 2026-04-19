#!/usr/bin/env bash
# test_apply_patch.sh — Tests for apply-patch.lua custom patch format parser
#
# Exercises the Lua parser directly (nvim --headless -l) without the
# OpenCode TypeScript harness. Verifies that the *** Begin Patch / *** Update
# File / *** Add File / *** Delete File format is correctly parsed and
# per-file original/proposed pairs are computed.

APPLY_PATCH="$REPO_ROOT/bin/apply-patch.lua"

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
TEST_OUTDIR="$(mktemp -d /tmp/code-preview-patch-test.XXXXXX)"

# Helper: run apply-patch.lua with a patch string, return output dir
run_apply_patch() {
  local patch_text="$1"
  local outdir="$TEST_OUTDIR/run-$$-$RANDOM"
  mkdir -p "$outdir"

  local patch_json="$outdir/input.json"
  # Use jq to properly escape the patch text into JSON
  jq -n --arg pt "$patch_text" '{patch_text: $pt}' > "$patch_json"

  NVIM_LISTEN_ADDRESS= nvim --headless --clean -l "$APPLY_PATCH" "$patch_json" "$TEST_PROJECT_DIR" "$outdir" 2>/dev/null

  echo "$outdir"
}

# ── Test: Update existing file ───────────────────────────────────

test_patch_update_file() {
  create_test_file "hello.txt" "line one
line two
line three" >/dev/null

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

  local outdir
  outdir="$(run_apply_patch "$patch")"

  assert_file_exists "$outdir/files.json" "files.json should exist" || return 1

  local count
  count=$(jq 'length' "$outdir/files.json")
  assert_eq "1" "$count" "should have 1 file entry" || return 1

  local action
  action=$(jq -r '.[0].action' "$outdir/files.json")
  assert_eq "update" "$action" "action should be 'update'" || return 1

  local rel_path
  rel_path=$(jq -r '.[0].rel_path' "$outdir/files.json")
  assert_eq "hello.txt" "$rel_path" "rel_path should be hello.txt" || return 1

  # Check proposed content has the modification
  local prop_file
  prop_file=$(jq -r '.[0].prop' "$outdir/files.json")
  local prop_content
  prop_content="$(cat "$prop_file")"
  assert_contains "$prop_content" "line two modified" "proposed should contain modified line" || return 1
  assert_not_contains "$prop_content" $'\nline two\n' "proposed should not contain original line two" || return 1

  # Check original content is preserved
  local orig_file
  orig_file=$(jq -r '.[0].orig' "$outdir/files.json")
  local orig_content
  orig_content="$(cat "$orig_file")"
  assert_contains "$orig_content" "line two" "original should contain unmodified line" || return 1
}

# ── Test: Add new file ───────────────────────────────────────────

test_patch_add_file() {
  local patch
  patch=$(printf '%s\n' \
    "*** Begin Patch" \
    "*** Add File: src/new_file.lua" \
    "@@" \
    "+local M = {}" \
    "+return M" \
    "*** End Patch")

  local outdir
  outdir="$(run_apply_patch "$patch")"

  assert_file_exists "$outdir/files.json" "files.json should exist" || return 1

  local action
  action=$(jq -r '.[0].action' "$outdir/files.json")
  assert_eq "add" "$action" "action should be 'add'" || return 1

  # Original should be empty for new files
  local orig_file
  orig_file=$(jq -r '.[0].orig' "$outdir/files.json")
  local orig_size
  orig_size=$(wc -c < "$orig_file" | tr -d ' ')
  assert_eq "0" "$orig_size" "original should be empty for new file" || return 1

  # Proposed should contain the new content
  local prop_file
  prop_file=$(jq -r '.[0].prop' "$outdir/files.json")
  local prop_content
  prop_content="$(cat "$prop_file")"
  assert_contains "$prop_content" "local M = {}" "proposed should have first line" || return 1
  assert_contains "$prop_content" "return M" "proposed should have second line" || return 1
}

# ── Test: Delete file ────────────────────────────────────────────

test_patch_delete_file() {
  create_test_file "to_delete.txt" "some content here" >/dev/null

  local patch
  patch=$(printf '%s\n' \
    "*** Begin Patch" \
    "*** Delete File: to_delete.txt" \
    "*** End Patch")

  local outdir
  outdir="$(run_apply_patch "$patch")"

  assert_file_exists "$outdir/files.json" "files.json should exist" || return 1

  local action
  action=$(jq -r '.[0].action' "$outdir/files.json")
  assert_eq "delete" "$action" "action should be 'delete'" || return 1

  # Original should have the file content
  local orig_file
  orig_file=$(jq -r '.[0].orig' "$outdir/files.json")
  local orig_content
  orig_content="$(cat "$orig_file")"
  assert_contains "$orig_content" "some content here" "original should have file content" || return 1

  # Proposed should be empty
  local prop_file
  prop_file=$(jq -r '.[0].prop' "$outdir/files.json")
  local prop_size
  prop_size=$(wc -c < "$prop_file" | tr -d ' ')
  assert_eq "0" "$prop_size" "proposed should be empty for deleted file" || return 1
}

# ── Test: Multi-file patch ───────────────────────────────────────

test_patch_multi_file() {
  create_test_file "file_a.txt" "alpha
beta
gamma" >/dev/null

  local patch
  patch=$(printf '%s\n' \
    "*** Begin Patch" \
    "*** Update File: file_a.txt" \
    "@@" \
    " alpha" \
    "-beta" \
    "+beta updated" \
    " gamma" \
    "*** Add File: file_b.txt" \
    "@@" \
    "+new file content" \
    "*** End Patch")

  local outdir
  outdir="$(run_apply_patch "$patch")"

  assert_file_exists "$outdir/files.json" "files.json should exist" || return 1

  local count
  count=$(jq 'length' "$outdir/files.json")
  assert_eq "2" "$count" "should have 2 file entries" || return 1

  local action0 action1
  action0=$(jq -r '.[0].action' "$outdir/files.json")
  action1=$(jq -r '.[1].action' "$outdir/files.json")
  assert_eq "update" "$action0" "first file should be update" || return 1
  assert_eq "add" "$action1" "second file should be add" || return 1

  # Verify update content
  local prop0
  prop0=$(jq -r '.[0].prop' "$outdir/files.json")
  assert_contains "$(cat "$prop0")" "beta updated" "first file proposed should have modification" || return 1

  # Verify add content
  local prop1
  prop1=$(jq -r '.[1].prop' "$outdir/files.json")
  assert_contains "$(cat "$prop1")" "new file content" "second file proposed should have new content" || return 1
}

# ── Test: Multiple hunks in same file ────────────────────────────

test_patch_multiple_hunks() {
  create_test_file "multi_hunk.txt" "line 1
line 2
line 3
line 4
line 5
line 6" >/dev/null

  local patch
  patch=$(printf '%s\n' \
    "*** Begin Patch" \
    "*** Update File: multi_hunk.txt" \
    "@@" \
    " line 1" \
    "-line 2" \
    "+line 2 changed" \
    " line 3" \
    "@@" \
    " line 5" \
    "-line 6" \
    "+line 6 changed" \
    "*** End Patch")

  local outdir
  outdir="$(run_apply_patch "$patch")"

  assert_file_exists "$outdir/files.json" "files.json should exist" || return 1

  local prop_file
  prop_file=$(jq -r '.[0].prop' "$outdir/files.json")
  local prop_content
  prop_content="$(cat "$prop_file")"

  assert_contains "$prop_content" "line 2 changed" "proposed should have first hunk change" || return 1
  assert_contains "$prop_content" "line 6 changed" "proposed should have second hunk change" || return 1
  assert_contains "$prop_content" "line 4" "proposed should preserve lines between hunks" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "apply-patch.lua parses Update File correctly" test_patch_update_file
run_test "apply-patch.lua parses Add File correctly" test_patch_add_file
run_test "apply-patch.lua parses Delete File correctly" test_patch_delete_file
run_test "apply-patch.lua handles multi-file patches" test_patch_multi_file
run_test "apply-patch.lua handles multiple hunks in same file" test_patch_multiple_hunks

# ── Teardown ─────────────────────────────────────────────────────

rm -rf "$TEST_OUTDIR"
cleanup_test_project
