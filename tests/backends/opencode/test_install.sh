#!/usr/bin/env bash
# test_install.sh — OpenCode plugin install/uninstall tests

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

# Change Neovim's cwd to the test project so hooks.lua writes settings there
nvim_exec "vim.cmd('cd $TEST_PROJECT_DIR')"

# ── Test: Install OpenCode plugin ────────────────────────────────

test_install_opencode() {
  nvim_exec "require('claude-preview.hooks').install_opencode()"
  sleep 0.3

  local target_dir="$TEST_PROJECT_DIR/.opencode/plugins"
  assert_file_exists "$target_dir/index.ts" "index.ts should be copied" || return 1
  assert_file_exists "$target_dir/package.json" "package.json should be copied" || return 1
  assert_file_exists "$target_dir/tsconfig.json" "tsconfig.json should be copied" || return 1
  assert_file_exists "$target_dir/bin-path.txt" "bin-path.txt should be written" || return 1
}

# ── Test: Uninstall OpenCode plugin ──────────────────────────────

test_uninstall_opencode() {
  # Install first
  nvim_exec "require('claude-preview.hooks').install_opencode()"
  sleep 0.2

  # Uninstall
  nvim_exec "require('claude-preview.hooks').uninstall_opencode()"
  sleep 0.2

  local target_dir="$TEST_PROJECT_DIR/.opencode/plugins"
  assert_file_not_exists "$target_dir/index.ts" "index.ts should be removed" || return 1
  assert_file_not_exists "$target_dir/bin-path.txt" "bin-path.txt should be removed" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "Install OpenCode plugin copies files" test_install_opencode
run_test "Uninstall OpenCode plugin removes files" test_uninstall_opencode

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
