#!/usr/bin/env bash
# test_install.sh — GitHub Copilot CLI hook install/uninstall tests
#
# Copilot auto-discovers every *.json under .github/hooks/, so the installer
# writes a standalone code-preview.json rather than merging into a shared
# settings file. These tests assert that contract — and, critically, that we
# never touch sibling files in .github/hooks/ (user hooks stay intact).

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

# Change Neovim's cwd to the test project so backend module writes hooks there
nvim_exec "vim.cmd('cd $TEST_PROJECT_DIR')"

HOOKS_FILE="$TEST_PROJECT_DIR/.github/hooks/code-preview.json"

# ── Test: Install writes the correct hook file ──────────────────

test_install_copilot_hooks() {
  rm -rf "$TEST_PROJECT_DIR/.github"
  nvim_exec "require('code-preview.backends.copilot').install()"
  sleep 0.3

  assert_file_exists "$HOOKS_FILE" "code-preview.json should be created" || return 1

  local content
  content="$(cat "$HOOKS_FILE")"

  # Version field must be present and set to 1
  local version
  version="$(jq -r '.version' "$HOOKS_FILE")"
  assert_eq "1" "$version" "version should be 1" || return 1

  # Both hook events are registered with the right adapter scripts
  assert_contains "$content" "preToolUse"         "should have preToolUse hook"  || return 1
  assert_contains "$content" "postToolUse"        "should have postToolUse hook" || return 1
  assert_contains "$content" "code-preview-diff.sh" "should reference pre-tool script"  || return 1
  assert_contains "$content" "code-close-diff.sh"   "should reference post-tool script" || return 1

  # Each event should have exactly one entry (no accidental duplication)
  local pre_count post_count
  pre_count="$(jq '.hooks.preToolUse  | length' "$HOOKS_FILE")"
  post_count="$(jq '.hooks.postToolUse | length' "$HOOKS_FILE")"
  assert_eq "1" "$pre_count"  "preToolUse should have 1 entry"  || return 1
  assert_eq "1" "$post_count" "postToolUse should have 1 entry" || return 1
}

# ── Test: Uninstall removes the hook file ───────────────────────

test_uninstall_copilot_hooks() {
  nvim_exec "require('code-preview.backends.copilot').install()"
  sleep 0.2
  assert_file_exists "$HOOKS_FILE" "precondition: file should exist" || return 1

  nvim_exec "require('code-preview.backends.copilot').uninstall()"
  sleep 0.2

  assert_file_not_exists "$HOOKS_FILE" "code-preview.json should be removed" || return 1
}

# ── Test: Install is idempotent ─────────────────────────────────

test_install_idempotent() {
  rm -rf "$TEST_PROJECT_DIR/.github"
  nvim_exec "require('code-preview.backends.copilot').install()"
  nvim_exec "require('code-preview.backends.copilot').install()"
  sleep 0.2

  # Re-running must still produce exactly one entry per event, not append.
  local pre_count post_count
  pre_count="$(jq '.hooks.preToolUse  | length' "$HOOKS_FILE")"
  post_count="$(jq '.hooks.postToolUse | length' "$HOOKS_FILE")"
  assert_eq "1" "$pre_count"  "preToolUse should still have 1 entry after re-install"  || return 1
  assert_eq "1" "$post_count" "postToolUse should still have 1 entry after re-install" || return 1
}

# ── Test: Install preserves sibling hook files ──────────────────

# Copilot aggregates every *.json under .github/hooks/, so a user may keep
# their own policy.json alongside ours. Install/uninstall must never touch it.
test_install_preserves_sibling_hooks() {
  rm -rf "$TEST_PROJECT_DIR/.github"
  mkdir -p "$TEST_PROJECT_DIR/.github/hooks"
  local sibling="$TEST_PROJECT_DIR/.github/hooks/user-policy.json"
  printf '%s\n' '{"version":1,"hooks":{"preToolUse":[{"type":"command","bash":"echo user"}]}}' > "$sibling"

  nvim_exec "require('code-preview.backends.copilot').install()"
  sleep 0.2

  assert_file_exists "$sibling"     "sibling hook file should still exist after install"    || return 1
  assert_file_exists "$HOOKS_FILE"  "our hook file should also be present"                  || return 1

  local sibling_content
  sibling_content="$(cat "$sibling")"
  assert_contains "$sibling_content" "echo user" "sibling file contents should be untouched" || return 1

  nvim_exec "require('code-preview.backends.copilot').uninstall()"
  sleep 0.2

  assert_file_not_exists "$HOOKS_FILE" "our file should be removed on uninstall" || return 1
  assert_file_exists     "$sibling"    "sibling hook file must survive uninstall" || return 1
}

# ── Test: Uninstall refuses to delete foreign code-preview.json ─

# If a user happens to have their own .github/hooks/code-preview.json that
# wasn't produced by our installer, uninstall must leave it alone. We
# identify our file by the presence of the adapter script name.
test_uninstall_refuses_foreign_file() {
  rm -rf "$TEST_PROJECT_DIR/.github"
  mkdir -p "$TEST_PROJECT_DIR/.github/hooks"
  # User-owned file that happens to share the name but references a
  # different script — our installer would never produce this.
  printf '%s\n' '{"version":1,"hooks":{"preToolUse":[{"type":"command","bash":"echo user-owned"}]}}' \
    > "$HOOKS_FILE"

  nvim_exec "require('code-preview.backends.copilot').uninstall()"
  sleep 0.2

  assert_file_exists "$HOOKS_FILE" "foreign code-preview.json must survive uninstall" || return 1

  local content
  content="$(cat "$HOOKS_FILE")"
  assert_contains "$content" "echo user-owned" "foreign file contents must be untouched" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "Install Copilot CLI hooks writes correct config"       test_install_copilot_hooks
run_test "Uninstall Copilot CLI hooks removes config file"       test_uninstall_copilot_hooks
run_test "Install is idempotent (no duplicate entries)"          test_install_idempotent
run_test "Install/uninstall preserves sibling hook files"        test_install_preserves_sibling_hooks
run_test "Uninstall refuses to delete foreign code-preview.json" test_uninstall_refuses_foreign_file

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
