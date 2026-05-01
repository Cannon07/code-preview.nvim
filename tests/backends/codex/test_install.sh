#!/usr/bin/env bash
# test_install.sh — OpenAI Codex CLI hook install/uninstall tests
#
# Codex reads hooks from .codex/hooks.json and requires `codex_hooks = true`
# under [features] in .codex/config.toml. Our installer writes hooks.json
# (merging with any existing entries) and warns if the feature flag is
# missing — it does NOT edit config.toml. These tests pin that contract.

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

nvim_exec "vim.cmd('cd $TEST_PROJECT_DIR')"

HOOKS_FILE="$TEST_PROJECT_DIR/.codex/hooks.json"
CONFIG_FILE="$TEST_PROJECT_DIR/.codex/config.toml"

# Redirect the "global" config path used by feature_flag_state away from
# the user's real ~/.codex/config.toml so this test never touches it.
GLOBAL_CONFIG_FILE="$TEST_PROJECT_DIR/.fake-home-codex-config.toml"
nvim_exec "vim.env.CODE_PREVIEW_CODEX_GLOBAL_CONFIG = '$GLOBAL_CONFIG_FILE'"
rm -f "$GLOBAL_CONFIG_FILE"

# ── Test: Install writes the correct hook file ──────────────────

test_install_codex_hooks() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  nvim_exec "require('code-preview.backends.codex').install()"
  sleep 0.3

  assert_file_exists "$HOOKS_FILE" "hooks.json should be created" || return 1

  # Both hook events present and pointing at our adapter scripts
  local content
  content="$(cat "$HOOKS_FILE")"
  assert_contains "$content" "PreToolUse"            "should have PreToolUse hook"  || return 1
  assert_contains "$content" "PostToolUse"           "should have PostToolUse hook" || return 1
  assert_contains "$content" "code-preview-diff.sh"  "should reference pre-tool script"  || return 1
  assert_contains "$content" "code-close-diff.sh"    "should reference post-tool script" || return 1

  # Exactly one entry per event after a fresh install.
  local pre_count post_count
  pre_count="$(jq '.hooks.PreToolUse  | length' "$HOOKS_FILE")"
  post_count="$(jq '.hooks.PostToolUse | length' "$HOOKS_FILE")"
  assert_eq "1" "$pre_count"  "PreToolUse should have 1 entry"  || return 1
  assert_eq "1" "$post_count" "PostToolUse should have 1 entry" || return 1
}

# ── Test: Install is idempotent ─────────────────────────────────

# Re-running install must not append duplicate entries — `is_installed()`
# uses our adapter path as the marker, and we filter them out before
# inserting on every install.
test_install_idempotent() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  nvim_exec "require('code-preview.backends.codex').install()"
  nvim_exec "require('code-preview.backends.codex').install()"
  sleep 0.3

  local pre_count post_count
  pre_count="$(jq '.hooks.PreToolUse  | length' "$HOOKS_FILE")"
  post_count="$(jq '.hooks.PostToolUse | length' "$HOOKS_FILE")"
  assert_eq "1" "$pre_count"  "PreToolUse should still have 1 entry after re-install"  || return 1
  assert_eq "1" "$post_count" "PostToolUse should still have 1 entry after re-install" || return 1
}

# ── Test: Install preserves user-authored hook entries ──────────

# Codex supports stacking multiple hooks per event. A user might have their
# own logging or policy hook alongside ours. Install must merge, not stomp.
test_install_preserves_user_hooks() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  mkdir -p "$TEST_PROJECT_DIR/.codex"

  # User-authored hooks.json with unrelated commands in BOTH PreToolUse and
  # PostToolUse — install must preserve user entries on both events.
  cat > "$HOOKS_FILE" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/usr/bin/true # user-pre-policy" } ] }
    ],
    "PostToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/usr/bin/true # user-post-policy" } ] }
    ]
  }
}
EOF

  nvim_exec "require('code-preview.backends.codex').install()"
  sleep 0.3

  # Both user entries must survive.
  local content
  content="$(cat "$HOOKS_FILE")"
  assert_contains "$content" "user-pre-policy"  "user PreToolUse entry should survive install"  || return 1
  assert_contains "$content" "user-post-policy" "user PostToolUse entry should survive install" || return 1

  # Both ours and theirs should be present in PreToolUse and PostToolUse.
  local pre_count post_count
  pre_count="$(jq  '.hooks.PreToolUse  | length' "$HOOKS_FILE")"
  post_count="$(jq '.hooks.PostToolUse | length' "$HOOKS_FILE")"
  assert_eq "2" "$pre_count"  "PreToolUse should now have 2 entries (user + ours)"  || return 1
  assert_eq "2" "$post_count" "PostToolUse should now have 2 entries (user + ours)" || return 1
}

# ── Test: Uninstall removes only our entries ────────────────────

test_uninstall_preserves_user_hooks() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  mkdir -p "$TEST_PROJECT_DIR/.codex"

  cat > "$HOOKS_FILE" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/usr/bin/true # user-policy" } ] }
    ]
  }
}
EOF

  nvim_exec "require('code-preview.backends.codex').install()"
  sleep 0.2
  nvim_exec "require('code-preview.backends.codex').uninstall()"
  sleep 0.2

  # File should still exist (we don't delete it — user may have other entries).
  assert_file_exists "$HOOKS_FILE" "hooks.json should not be deleted on uninstall" || return 1

  local content
  content="$(cat "$HOOKS_FILE")"
  assert_contains     "$content" "user-policy"           "user entry must survive uninstall"     || return 1
  assert_not_contains "$content" "code-preview-diff.sh"  "our pre-hook must be removed"          || return 1
  assert_not_contains "$content" "code-close-diff.sh"    "our post-hook must be removed"         || return 1
}

# ── Test: feature_flag_state reports the three modes ────────────

# Drives the helper that :CodePreviewStatus and :checkhealth use to surface
# the codex_hooks feature flag. The flag is the silent failure mode for
# Codex hooks, so the detector must not produce false positives or negatives.
test_feature_flag_state() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  rm -f  "$GLOBAL_CONFIG_FILE"

  # Both project-local and global absent.
  local missing
  missing="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "missing" "$missing" "no config files should report 'missing'" || return 1

  # Project-local exists without the flag, global still absent → disabled.
  mkdir -p "$TEST_PROJECT_DIR/.codex"
  cat > "$CONFIG_FILE" <<'EOF'
approval_policy = "on-request"
EOF
  local disabled
  disabled="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "disabled" "$disabled" "config.toml without flag should report 'disabled'" || return 1

  # Project-local has the flag → enabled.
  cat > "$CONFIG_FILE" <<'EOF'
approval_policy = "on-request"

[features]
codex_hooks = true
EOF
  local enabled
  enabled="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "enabled" "$enabled" "config.toml with flag should report 'enabled'" || return 1
}

# ── Test: feature_flag_state honors the global config.toml ──────

# Codex reads ~/.codex/config.toml (global) in addition to .codex/config.toml
# (project-local). A user with the flag set globally should NOT see a
# misleading "disabled/missing" warning. Mirrors the docs we link in README.
test_feature_flag_state_global() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  rm -f  "$GLOBAL_CONFIG_FILE"

  # Only the global file has the flag — project-local is absent.
  cat > "$GLOBAL_CONFIG_FILE" <<'EOF'
[features]
codex_hooks = true
EOF
  local enabled
  enabled="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "enabled" "$enabled" "global config with flag should report 'enabled'" || return 1

  # Project-local without the flag must NOT downgrade an enabled global.
  mkdir -p "$TEST_PROJECT_DIR/.codex"
  cat > "$CONFIG_FILE" <<'EOF'
approval_policy = "on-request"
EOF
  local still_enabled
  still_enabled="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "enabled" "$still_enabled" "global flag should win over local-without-flag" || return 1

  # Both files present, neither enables → disabled (not missing).
  rm -f "$GLOBAL_CONFIG_FILE"
  cat > "$GLOBAL_CONFIG_FILE" <<'EOF'
# nothing useful here
EOF
  local disabled
  disabled="$(nvim_eval "require('code-preview.backends.codex').feature_flag_state()")"
  assert_eq "disabled" "$disabled" "two configs, neither enabling, should be 'disabled'" || return 1
}

# ── Test: install refuses to overwrite a corrupted hooks.json ───

# Hand-edits or interrupted writes can leave hooks.json in an unparseable
# state. Silent overwrite would destroy whatever the user had. Install must
# bail with a clear error so the user can recover.
test_install_refuses_corrupted_hooks_json() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  mkdir -p "$TEST_PROJECT_DIR/.codex"
  # Garbage that can never decode as JSON.
  printf '%s\n' '{ this is not valid json at all' > "$HOOKS_FILE"

  local original_content
  original_content="$(cat "$HOOKS_FILE")"

  nvim_exec "require('code-preview.backends.codex').install()"
  sleep 0.3

  # File contents must be unchanged.
  local after_content
  after_content="$(cat "$HOOKS_FILE")"
  assert_eq "$original_content" "$after_content" \
    "corrupted hooks.json must not be overwritten on install" || return 1

  # is_installed should still be false because we bailed.
  local installed
  installed="$(nvim_eval "require('code-preview.backends.codex').is_installed()")"
  assert_eq "false" "$installed" "install should not register after bailing on corrupt JSON" || return 1
}

# ── Test: uninstall surfaces corrupted JSON instead of stomping ─

test_uninstall_handles_corrupted_hooks_json() {
  rm -rf "$TEST_PROJECT_DIR/.codex"
  mkdir -p "$TEST_PROJECT_DIR/.codex"
  printf '%s\n' '{ broken' > "$HOOKS_FILE"

  local original_content
  original_content="$(cat "$HOOKS_FILE")"

  nvim_exec "require('code-preview.backends.codex').uninstall()"
  sleep 0.3

  local after_content
  after_content="$(cat "$HOOKS_FILE")"
  assert_eq "$original_content" "$after_content" \
    "corrupted hooks.json must not be modified on uninstall" || return 1
}

# ── Test: is_installed reflects current hooks.json state ────────

test_is_installed_detection() {
  rm -rf "$TEST_PROJECT_DIR/.codex"

  local before
  before="$(nvim_eval "require('code-preview.backends.codex').is_installed()")"
  assert_eq "false" "$before" "is_installed should be false when nothing is set up" || return 1

  nvim_exec "require('code-preview.backends.codex').install()"
  sleep 0.2
  local after
  after="$(nvim_eval "require('code-preview.backends.codex').is_installed()")"
  assert_eq "true" "$after" "is_installed should be true after install" || return 1

  nvim_exec "require('code-preview.backends.codex').uninstall()"
  sleep 0.2
  local removed
  removed="$(nvim_eval "require('code-preview.backends.codex').is_installed()")"
  assert_eq "false" "$removed" "is_installed should be false after uninstall" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "Install Codex CLI hooks writes correct config"        test_install_codex_hooks
run_test "Install is idempotent (no duplicate entries)"         test_install_idempotent
run_test "Install preserves user-authored hook entries"         test_install_preserves_user_hooks
run_test "Uninstall preserves user-authored hook entries"       test_uninstall_preserves_user_hooks
run_test "feature_flag_state reports missing/disabled/enabled"  test_feature_flag_state
run_test "feature_flag_state honors global ~/.codex/config.toml" test_feature_flag_state_global
run_test "Install refuses to overwrite corrupted hooks.json"     test_install_refuses_corrupted_hooks_json
run_test "Uninstall doesn't stomp corrupted hooks.json"          test_uninstall_handles_corrupted_hooks_json
run_test "is_installed reflects hooks.json state"               test_is_installed_detection

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
