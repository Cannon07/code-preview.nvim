#!/usr/bin/env bash
# test_edit.sh — E2E tests for Codex CLI Bash + edit workflows
#
# Drives Codex's hook payload shape ({tool_name, tool_input, cwd}) through
# backends/codex/code-preview-diff.sh (pre) and code-close-diff.sh (post),
# then verifies Neovim state via RPC.
#
# Codex specifics:
#   - apply_patch carries the patch text in tool_input.command (not patch_text).
#     The adapter rewrites that field; covered in test_apply_patch.sh.
#   - Today's models route ALL file edits through apply_patch. Edit/Write/
#     MultiEdit are passed through defensively for forward compat.
#   - Bash detection: rm marks deleted; output redirection (Tier 1 shell
#     writes) marks bash_modified / bash_created. Both clear on PostToolUse.

CODEX_PRE="$REPO_ROOT/backends/codex/code-preview-diff.sh"
CODEX_POST="$REPO_ROOT/backends/codex/code-close-diff.sh"

# Feed a Codex-shaped payload to the pre-tool adapter.
#   $1 = tool_name, $2 = tool_input (JSON object)
run_codex_pre() {
  local tool_name="$1"
  local tool_input="$2"
  local payload
  payload=$(jq -n \
    --arg tn "$tool_name" \
    --arg cwd "$TEST_PROJECT_DIR" \
    --argjson ti "$tool_input" \
    '{tool_name:$tn, cwd:$cwd, tool_input:$ti}')
  echo "$payload" | \
    NVIM_LISTEN_ADDRESS="$TEST_SOCKET" \
    bash "$CODEX_PRE" 2>/dev/null || true
}

run_codex_post() {
  local tool_name="$1"
  local tool_input="$2"
  local payload
  payload=$(jq -n \
    --arg tn "$tool_name" \
    --arg cwd "$TEST_PROJECT_DIR" \
    --argjson ti "$tool_input" \
    '{tool_name:$tn, cwd:$cwd, tool_input:$ti}')
  echo "$payload" | \
    NVIM_LISTEN_ADDRESS="$TEST_SOCKET" \
    bash "$CODEX_POST" 2>/dev/null || true
}

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

# ── Test: defensive Edit passthrough ────────────────────────────

# Codex doesn't currently emit `Edit` (it routes via apply_patch), but the
# adapter passes it through anyway in case a future Codex version or MCP
# tool uses Claude-Code-style {file_path, old_string, new_string} payloads.
test_codex_edit_passthrough() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "src/cx_edit.lua" 'local x = 1')"

  local tool_input
  tool_input=$(jq -nc \
    --arg p "$test_file" \
    --arg o "local x = 1" \
    --arg n "local x = 99" \
    '{file_path:$p, old_string:$o, new_string:$n}')

  run_codex_pre "Edit" "$tool_input"
  sleep 0.5

  assert_eq "true" "$(nvim_eval "require('code-preview.diff').is_open()")" \
    "diff should open on Edit passthrough" || return 1
  assert_eq "modified" "$(nvim_eval "require('code-preview.changes').get('$test_file')")" \
    "Edit should mark file as modified" || return 1

  run_codex_post "Edit" "$tool_input"
  sleep 0.5

  assert_eq "false" "$(nvim_eval "require('code-preview.diff').is_open()")" \
    "diff should close after Edit post" || return 1
}

# ── Test: defensive Write passthrough ───────────────────────────

test_codex_write_passthrough() {
  reset_test_state
  local new_file="$TEST_PROJECT_DIR/src/cx_new.lua"

  local tool_input
  tool_input=$(jq -nc \
    --arg p "$new_file" \
    --arg c "local M = {}
return M" \
    '{file_path:$p, content:$c}')

  run_codex_pre "Write" "$tool_input"
  sleep 0.5

  assert_eq "true" "$(nvim_eval "require('code-preview.diff').is_open()")" \
    "diff should open on Write passthrough" || return 1
  assert_eq "created" "$(nvim_eval "require('code-preview.changes').get('$new_file')")" \
    "Write should mark new file as created" || return 1

  run_codex_post "Write" "$tool_input"
  sleep 0.5

  assert_eq "false" "$(nvim_eval "require('code-preview.diff').is_open()")" \
    "diff should close after Write post" || return 1
}

# ── Test: Bash rm marks target as deleted ───────────────────────

test_codex_bash_rm() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "cx_delete_me.txt" 'goodbye')"

  local tool_input
  tool_input=$(jq -nc --arg cmd "rm $test_file" '{command:$cmd}')

  run_codex_pre "Bash" "$tool_input"
  sleep 0.4

  assert_eq "deleted" "$(nvim_eval "require('code-preview.changes').get('$test_file')")" \
    "rm target should be marked as deleted" || return 1

  run_codex_post "Bash" "$tool_input"
  sleep 0.4

  assert_eq "nil" "$(nvim_eval "require('code-preview.changes').get('$test_file') or 'nil'")" \
    "deletion marker should be cleared on Bash post" || return 1
}

# ── Test: Tier 1 shell-write detection (bash_modified) ──────────

# Codex sometimes performs file edits via shell redirection instead of
# apply_patch (e.g. `printf … >> file`). Tier 1 detection extracts the
# target path and marks it bash_modified so the user gets a neo-tree icon
# during the approval window.
test_codex_bash_shell_write_modified() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "cx_shell_target.txt" "original line")"

  # Append to existing file via redirection.
  local tool_input
  tool_input=$(jq -nc --arg cmd "printf 'extra\n' >> $test_file" '{command:$cmd}')

  run_codex_pre "Bash" "$tool_input"
  sleep 0.4

  assert_eq "bash_modified" "$(nvim_eval "require('code-preview.changes').get('$test_file')")" \
    "shell-write target on existing file should be bash_modified" || return 1

  run_codex_post "Bash" "$tool_input"
  sleep 0.4

  assert_eq "nil" "$(nvim_eval "require('code-preview.changes').get('$test_file') or 'nil'")" \
    "bash_modified marker should clear on Bash post" || return 1
}

# ── Test: Tier 1 — atomic-replace idiom (mv X.tmp X) ────────────

# This is the specific pattern Codex's GPT models use for prepend/rewrite:
#   `{ printf …; cat F; } > F.tmp && mv F.tmp F`
# Detection should flag F as bash_modified (existing) and filter F.tmp
# (transient). The .tmp side falls under is_transient_path.
test_codex_bash_atomic_replace() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "cx_atomic.txt" "original\n")"

  local cmd="{ printf 'note\\n'; cat $test_file; } > $test_file.tmp && mv $test_file.tmp $test_file"
  local tool_input
  tool_input=$(jq -nc --arg cmd "$cmd" '{command:$cmd}')

  run_codex_pre "Bash" "$tool_input"
  sleep 0.4

  assert_eq "bash_modified" "$(nvim_eval "require('code-preview.changes').get('$test_file')")" \
    "atomic-replace target should be marked bash_modified" || return 1

  # The .tmp file should NOT be in the changes registry (filtered as transient).
  assert_eq "nil" "$(nvim_eval "require('code-preview.changes').get('$test_file.tmp') or 'nil'")" \
    "atomic-replace .tmp file should be filtered out" || return 1

  run_codex_post "Bash" "$tool_input"
  sleep 0.4
}

# ── Test: Tier 1 — write to non-existent file marks bash_created ─

test_codex_bash_shell_write_created() {
  reset_test_state
  local new_file="$TEST_PROJECT_DIR/cx_brand_new.txt"
  [[ -f "$new_file" ]] && rm -f "$new_file"

  local tool_input
  tool_input=$(jq -nc --arg cmd "printf 'hello\n' > $new_file" '{command:$cmd}')

  run_codex_pre "Bash" "$tool_input"
  sleep 0.4

  assert_eq "bash_created" "$(nvim_eval "require('code-preview.changes').get('$new_file')")" \
    "shell-write to non-existent file should be bash_created" || return 1

  run_codex_post "Bash" "$tool_input"
  sleep 0.4

  assert_eq "nil" "$(nvim_eval "require('code-preview.changes').get('$new_file') or 'nil'")" \
    "bash_created marker should clear on Bash post" || return 1
}

# ── Test: Tier 1 — read-only Bash commands don't pollute registry ─

# Pure-read commands (ls, cat, grep) must NOT mark anything. The detector
# only fires on write indicators, so this should be a true no-op.
test_codex_bash_readonly_no_marks() {
  reset_test_state

  local tool_input
  tool_input=$(jq -nc --arg cmd "ls -la $TEST_PROJECT_DIR" '{command:$cmd}')
  run_codex_pre "Bash" "$tool_input"
  sleep 0.3

  assert_eq "0" "$(nvim_eval "vim.tbl_count(require('code-preview.changes').get_all())")" \
    "read-only Bash command should not mark any files" || return 1
}

# ── Test: Tier 1 — false-positive guard for HTML comments in printf ─

# `<!-- … -->` inside a printf string contains `>` characters that the
# redirection regex would otherwise capture. looks_like_path() must filter
# the resulting `\n…'` capture so it doesn't reach the registry.
test_codex_bash_html_comment_false_positive() {
  reset_test_state
  local test_file
  test_file="$(create_test_file "cx_html.md" "# heading")"

  # The printf payload contains '-->' which the redirection regex sees as a
  # `>` boundary. Without the looks_like_path filter, this would mark a
  # bogus `\n\n'`-style entry.
  local cmd="{ printf '<!-- note -->\\n\\n'; cat $test_file; } > $test_file.tmp && mv $test_file.tmp $test_file"
  local tool_input
  tool_input=$(jq -nc --arg cmd "$cmd" '{command:$cmd}')

  run_codex_pre "Bash" "$tool_input"
  sleep 0.4

  # Exactly one entry — only the real target, no junk.
  assert_eq "1" "$(nvim_eval "vim.tbl_count(require('code-preview.changes').get_all())")" \
    "HTML-comment-in-printf must not produce phantom entries" || return 1
  assert_eq "bash_modified" "$(nvim_eval "require('code-preview.changes').get('$test_file')")" \
    "real target should still be detected" || return 1

  run_codex_post "Bash" "$tool_input"
  sleep 0.4
}

# ── Test: noise tools exit without side effects ─────────────────

# read/glob/grep and MCP tools (mcp__*) should be no-ops in the adapter.
test_codex_noise_tools_ignored() {
  reset_test_state

  run_codex_pre "read"            '{"path":"/tmp/whatever"}'
  run_codex_pre "glob"            '{"pattern":"**/*.lua"}'
  run_codex_pre "mcp__fs__read"   '{"path":"/tmp/x"}'
  sleep 0.3

  assert_eq "false" "$(nvim_eval "require('code-preview.diff').is_open()")" \
    "noise tools should not open a diff" || return 1
  assert_eq "0" "$(nvim_eval "vim.tbl_count(require('code-preview.changes').get_all())")" \
    "noise tools should not mark changes" || return 1
}

# ── Test: malformed payloads skip cleanly ───────────────────────

# Defensive: the adapter must exit 0 on missing/empty tool_input rather
# than push a broken diff downstream.
test_codex_malformed_payloads_skip() {
  reset_test_state

  # Edit with empty file_path
  run_codex_pre "Edit" '{"old_string":"a","new_string":"b"}'
  # Write with missing file_path
  run_codex_pre "Write" '{"content":"hello"}'
  # Bash with empty command
  run_codex_pre "Bash" '{}'
  # tool_input entirely absent
  local payload
  payload=$(jq -n --arg cwd "$TEST_PROJECT_DIR" '{tool_name:"Edit", cwd:$cwd}')
  echo "$payload" | NVIM_LISTEN_ADDRESS="$TEST_SOCKET" bash "$CODEX_PRE" 2>/dev/null || true

  sleep 0.3

  assert_eq "false" "$(nvim_eval "require('code-preview.diff').is_open()")" \
    "malformed payloads should not open a diff" || return 1
}

# ── Run all tests ────────────────────────────────────────────────

run_test "Codex Edit passthrough opens and closes diff"          test_codex_edit_passthrough
run_test "Codex Write passthrough marks file as created"         test_codex_write_passthrough
run_test "Codex Bash rm marks target as deleted"                 test_codex_bash_rm
run_test "Codex Bash shell write marks existing file modified"   test_codex_bash_shell_write_modified
run_test "Codex Bash atomic-replace idiom marks real target"     test_codex_bash_atomic_replace
run_test "Codex Bash shell write marks new file created"         test_codex_bash_shell_write_created
run_test "Codex Bash read-only commands leave registry empty"    test_codex_bash_readonly_no_marks
run_test "Codex Bash filters HTML-comment false positives"       test_codex_bash_html_comment_false_positive
run_test "Codex noise tools (read/glob/mcp__) ignored"           test_codex_noise_tools_ignored
run_test "Codex malformed payloads skip cleanly"                 test_codex_malformed_payloads_skip

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
