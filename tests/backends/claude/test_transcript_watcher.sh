#!/usr/bin/env bash
# test_transcript_watcher.sh — E2E tests for transcript-based rejection cleanup
#
# Tests three layers:
#   Layer 1: Pure bash (no nvim) — rejection detection, watcher lifecycle
#   Layer 2: Headless nvim integration — open diff, detect rejection, close diff
#   Layer 3: Edge cases — multi-session, rapid accept, focus state, permission bypass
#
# Every test captures wall-clock timing for the critical path.

# ── Setup ────────────────────────────────────────────────────────

setup_test_project
start_nvim

BIN_DIR="$REPO_ROOT/bin"

# Timing helper: returns current time in milliseconds
now_ms() {
  if command -v gdate >/dev/null 2>&1; then
    echo $(( $(gdate +%s%N) / 1000000 ))
  elif date +%s%N | grep -q N; then
    # macOS date doesn't support %N, fallback to python
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo $(( $(date +%s%N) / 1000000 ))
  fi
}

report_timing() {
  local label="$1" start_ms="$2" end_ms="$3"
  local elapsed=$(( end_ms - start_ms ))
  echo -e "    ${YELLOW}timing: ${label} = ${elapsed}ms${NC}"
}

# Source the transcript watcher library for direct function testing
source "$BIN_DIR/claude-preview-transcript-watch.sh"
source "$BIN_DIR/nvim-send.sh"
export NVIM_SOCKET="$TEST_SOCKET"

# Build a synthetic CC transcript JSONL line for a tool rejection
make_rejection_jsonl() {
  local tool_use_id="$1"
  printf '{"type":"tool_result","message":{"content":[{"tool_use_id":"%s","is_error":true,"content":"The user doesn'\''t want to proceed with this tool use."}]}}\n' "$tool_use_id"
}

# Build a synthetic CC transcript JSONL line for a tool acceptance (non-error)
make_acceptance_jsonl() {
  local tool_use_id="$1"
  printf '{"type":"tool_result","message":{"content":[{"tool_use_id":"%s","content":"Tool executed successfully."}]}}\n' "$tool_use_id"
}

# Build a synthetic CC transcript JSONL line for a different tool
make_unrelated_jsonl() {
  local tool_use_id="$1"
  printf '{"type":"tool_result","message":{"content":[{"tool_use_id":"%s","is_error":true,"content":"Some other error."}]}}\n' "$tool_use_id"
}

# Create a synthetic PreToolUse hook payload with transcript_path and tool_use_id
make_pretool_payload() {
  local file_path="$1"
  local transcript_path="$2"
  local tool_use_id="$3"
  local cwd="${4:-$TEST_PROJECT_DIR}"
  cat <<EOF
{
  "tool_name": "Edit",
  "cwd": "$cwd",
  "transcript_path": "$transcript_path",
  "tool_use_id": "$tool_use_id",
  "tool_input": {
    "file_path": "$file_path",
    "old_string": "hello",
    "new_string": "world",
    "replace_all": false
  }
}
EOF
}

# ═══════════════════════════════════════════════════════════════════
# LAYER 1: Pure bash — no nvim needed
# ═══════════════════════════════════════════════════════════════════

# ── Test: rejection line detection (positive match) ──────────────

test_line_is_rejection_positive() {
  local tool_use_id="toolu_01ABC123"
  local line
  line="$(make_rejection_jsonl "$tool_use_id")"

  local t0 t1
  t0="$(now_ms)"
  claude_preview_line_is_rejection "$line" "$tool_use_id"
  local rc=$?
  t1="$(now_ms)"

  report_timing "rejection detection" "$t0" "$t1"
  assert_eq "0" "$rc" "rejection line should match" || return 1
}

# ── Test: rejection line detection (wrong tool_use_id) ───────────

test_line_is_rejection_wrong_id() {
  local line
  line="$(make_rejection_jsonl "toolu_AAAA")"

  claude_preview_line_is_rejection "$line" "toolu_BBBB"
  local rc=$?

  assert_eq "1" "$rc" "different tool_use_id should not match" || return 1
}

# ── Test: rejection line detection (acceptance, not rejection) ───

test_line_is_rejection_acceptance() {
  local tool_use_id="toolu_01ACC"
  local line
  line="$(make_acceptance_jsonl "$tool_use_id")"

  claude_preview_line_is_rejection "$line" "$tool_use_id"
  local rc=$?

  assert_eq "1" "$rc" "acceptance line should not match as rejection" || return 1
}

# ── Test: rejection line detection (unrelated tool) ──────────────

test_line_is_rejection_unrelated() {
  local line
  line="$(make_unrelated_jsonl "toolu_OTHER")"

  claude_preview_line_is_rejection "$line" "toolu_MINE"
  local rc=$?

  assert_eq "1" "$rc" "unrelated tool's error should not match" || return 1
}

# ── Test: rejection line detection (garbage input) ───────────────

test_line_is_rejection_garbage() {
  claude_preview_line_is_rejection "this is not json" "toolu_01"
  local rc=$?
  # jq returns various non-zero codes (1 for false, 2+ for errors); any non-zero is correct
  if [[ "$rc" -eq 0 ]]; then
    echo -e "  ${RED}FAIL: garbage input should not match (got rc=0)${NC}" >&2
    return 1
  fi
}

# ── Test: state dir lifecycle ────────────────────────────────────

test_state_dir_lifecycle() {
  local transcript="/tmp/test-transcript-$$"
  local tool_id="toolu_LIFECYCLE"

  local state_dir pidfile stopfile
  state_dir="$(claude_preview_watch_state_dir "$transcript" "$tool_id")"
  pidfile="$(claude_preview_watch_pidfile "$transcript" "$tool_id")"
  stopfile="$(claude_preview_watch_stopfile "$transcript" "$tool_id")"

  # State dir should not exist yet
  assert_file_not_exists "$pidfile" "pidfile should not exist before watcher starts" || return 1

  # Create state dir as watcher would
  mkdir -p "$state_dir"
  echo "12345" > "$pidfile"
  assert_file_exists "$pidfile" "pidfile should exist after creation" || return 1

  # Stopfile creation
  : > "$stopfile"
  assert_file_exists "$stopfile" "stopfile should exist after touch" || return 1

  # Deterministic: same inputs produce same state dir
  local state_dir2
  state_dir2="$(claude_preview_watch_state_dir "$transcript" "$tool_id")"
  assert_eq "$state_dir" "$state_dir2" "same inputs should produce same state dir" || return 1

  # Different inputs produce different state dir
  local state_dir3
  state_dir3="$(claude_preview_watch_state_dir "$transcript" "toolu_OTHER")"
  if [[ "$state_dir" == "$state_dir3" ]]; then
    echo -e "  ${RED}FAIL: different tool_use_id should produce different state dir${NC}" >&2
    return 1
  fi

  # Cleanup
  rm -rf "$state_dir"
}

# ── Test: stop_transcript_watcher with no running watcher ────────

test_stop_watcher_noop() {
  # Should not error when no watcher exists
  claude_preview_stop_transcript_watcher "/tmp/nonexistent" "toolu_NOOP"
  local rc=$?
  assert_eq "0" "$rc" "stopping nonexistent watcher should succeed silently" || return 1
}

# ── Test: watcher starts and stops on stopfile ───────────────────

test_watcher_stops_on_stopfile() {
  # Need a diff open so the watcher doesn't exit immediately from is_open check
  open_test_diff || return 1

  local transcript
  transcript="$(mktemp /tmp/test-transcript-XXXXXX.jsonl)"
  local tool_id="toolu_STOPTEST"
  echo '{"type":"init"}' > "$transcript"

  local t0 t1

  claude_preview_watch_transcript "$transcript" "$tool_id" &
  local watcher_pid=$!
  sleep 0.5

  # Watcher should be running
  kill -0 "$watcher_pid" 2>/dev/null
  assert_eq "0" "$?" "watcher should be running" || { kill "$watcher_pid" 2>/dev/null; rm -f "$transcript"; return 1; }

  t0="$(now_ms)"
  # Signal it to stop via the library function (creates stopfile + sends TERM)
  claude_preview_stop_transcript_watcher "$transcript" "$tool_id"

  # Wait for it to exit
  wait "$watcher_pid" 2>/dev/null || true
  t1="$(now_ms)"

  report_timing "watcher stop on stopfile" "$t0" "$t1"

  # Should have exited
  ! kill -0 "$watcher_pid" 2>/dev/null
  assert_eq "0" "$?" "watcher should have exited after stopfile" || return 1

  nvim_exec "require('claude-preview.diff').close_diff()"
  sleep 0.2
  rm -f "$transcript"
}

# ── Test: nvim_diff_is_open shell function (live socket) ─────────

test_nvim_diff_is_open_live_socket() {
  # With no diff open, should return false (non-zero)
  claude_preview_nvim_diff_is_open
  local rc=$?
  assert_eq "1" "$rc" "is_open should return false when no diff is open" || return 1

  # Open a diff, should return true (zero)
  open_test_diff || return 1
  claude_preview_nvim_diff_is_open
  rc=$?
  assert_eq "0" "$rc" "is_open should return true when diff is open" || return 1

  nvim_exec "require('claude-preview.diff').close_diff()"
  sleep 0.2

  # After close, should return false again
  claude_preview_nvim_diff_is_open
  rc=$?
  assert_eq "1" "$rc" "is_open should return false after close" || return 1
}

# ── Test: nvim_diff_is_open shell function (dead socket) ─────────

test_nvim_diff_is_open_dead_socket() {
  local saved_socket="$NVIM_SOCKET"
  NVIM_SOCKET="/tmp/nonexistent-socket-$$"

  claude_preview_nvim_diff_is_open
  local rc=$?

  NVIM_SOCKET="$saved_socket"

  # Dead socket should return non-zero (treats as "not open")
  if [[ "$rc" -eq 0 ]]; then
    echo -e "  ${RED}FAIL: dead socket should return non-zero${NC}" >&2
    return 1
  fi
}

# ── Test: nvim_diff_is_open shell function (empty socket) ────────

test_nvim_diff_is_open_no_socket() {
  local saved_socket="$NVIM_SOCKET"
  NVIM_SOCKET=""

  claude_preview_nvim_diff_is_open
  local rc=$?

  NVIM_SOCKET="$saved_socket"

  if [[ "$rc" -eq 0 ]]; then
    echo -e "  ${RED}FAIL: empty socket should return non-zero${NC}" >&2
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════
# LAYER 2: Headless nvim integration
# ═══════════════════════════════════════════════════════════════════

# Helper: open a diff in the test nvim and verify it's open
open_test_diff() {
  local test_file
  test_file="$(create_test_file "src/target.lua" 'print("hello")')"

  local orig="${TMPDIR:-/tmp}/claude-diff-original"
  local prop="${TMPDIR:-/tmp}/claude-diff-proposed"
  cp "$test_file" "$orig"
  printf '%s' 'print("world")' > "$prop"

  nvim_exec "require('claude-preview.diff').show_diff('$orig', '$prop', 'src/target.lua')"
  sleep 0.3

  local is_open
  is_open="$(nvim_eval "require('claude-preview.diff').is_open()")"
  if [[ "$is_open" != "true" ]]; then
    echo -e "  ${RED}FAIL: diff should be open after show_diff${NC}" >&2
    return 1
  fi
  echo "$test_file"
}

# Helper: assert diff is closed
assert_diff_closed() {
  local msg="${1:-diff should be closed}"
  local is_open
  is_open="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "false" "$is_open" "$msg"
}

# Helper: assert diff is open
assert_diff_open() {
  local msg="${1:-diff should be open}"
  local is_open
  is_open="$(nvim_eval "require('claude-preview.diff').is_open()")"
  assert_eq "true" "$is_open" "$msg"
}

# Helper: count nvim tabs
count_tabs() {
  nvim_eval "vim.fn.tabpagenr('$')"
}

# Helper: count nvim buffers (listed)
count_listed_bufs() {
  nvim_eval "vim.tbl_count(vim.fn.getbufinfo({buflisted = 1}))"
}

# ── Test: diff open creates tab, close removes it ───────────────

test_diff_tab_lifecycle() {
  local tabs_before
  tabs_before="$(count_tabs)"

  open_test_diff || return 1

  local tabs_with_diff
  tabs_with_diff="$(count_tabs)"
  if (( tabs_with_diff <= tabs_before )); then
    echo -e "  ${RED}FAIL: show_diff should create a new tab (before=$tabs_before, after=$tabs_with_diff)${NC}" >&2
    return 1
  fi

  nvim_exec "require('claude-preview.diff').close_diff()"
  sleep 0.2

  local tabs_after
  tabs_after="$(count_tabs)"
  assert_eq "$tabs_before" "$tabs_after" "close_diff should remove the tab" || return 1
}

# ── Test: diff open creates scratch buffers that get wiped ───────

test_diff_buffers_are_scratch() {
  open_test_diff || return 1

  # Check the diff tab's buffers are nofile/scratch
  local buftypes
  buftypes="$(nvim_eval "(function() local tab = vim.api.nvim_get_current_tabpage() local wins = vim.api.nvim_tabpage_list_wins(tab) local types = {} for _, w in ipairs(wins) do local b = vim.api.nvim_win_get_buf(w) table.insert(types, vim.bo[b].buftype) end return table.concat(types, ',') end)()")"

  # ALL buffers in the diff tab must be nofile (not just one)
  local bad_type=""
  IFS=',' read -ra types <<< "$buftypes"
  for t in "${types[@]}"; do
    if [[ "$t" != "nofile" ]]; then
      bad_type="$t"
      break
    fi
  done
  if [[ -n "$bad_type" ]]; then
    echo -e "  ${RED}FAIL: all diff buffers should be nofile, got: $buftypes (bad: $bad_type)${NC}" >&2
    nvim_exec "require('claude-preview.diff').close_diff()"
    return 1
  fi

  nvim_exec "require('claude-preview.diff').close_diff()"
  sleep 0.2
}

# ── Test: watcher closes diff on rejection via nvim RPC ──────────

test_watcher_closes_diff_on_rejection() {
  open_test_diff || return 1

  local transcript
  transcript="$(mktemp /tmp/test-transcript-XXXXXX.jsonl)"
  local tool_id="toolu_NVIM_REJECT"
  echo '{"type":"init"}' > "$transcript"

  # Start watcher
  claude_preview_watch_transcript "$transcript" "$tool_id" &
  local watcher_pid=$!
  sleep 0.5

  # Verify diff is still open
  assert_diff_open "diff should still be open before rejection" || { kill "$watcher_pid" 2>/dev/null; rm -f "$transcript"; return 1; }

  # Write rejection to transcript
  local t0 t1
  t0="$(now_ms)"
  make_rejection_jsonl "$tool_id" >> "$transcript"

  # Wait for watcher to process and close the diff
  local tries=0
  while (( tries < 30 )); do
    local is_open
    is_open="$(nvim_eval "require('claude-preview.diff').is_open()")"
    if [[ "$is_open" == "false" ]]; then
      break
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  t1="$(now_ms)"

  report_timing "rejection -> diff close (e2e)" "$t0" "$t1"

  assert_diff_closed "diff should be closed after rejection" || { kill "$watcher_pid" 2>/dev/null; rm -f "$transcript"; return 1; }

  # Watcher should have exited
  wait "$watcher_pid" 2>/dev/null || true
  ! kill -0 "$watcher_pid" 2>/dev/null
  assert_eq "0" "$?" "watcher should have exited after closing diff" || return 1

  # Changes should be cleared
  local changes
  changes="$(nvim_eval "vim.tbl_count(require('claude-preview.changes').get_all())")"
  assert_eq "0" "$changes" "changes registry should be cleared after rejection close" || return 1

  # Temp files should be cleaned up by watcher's rejection handler
  assert_file_not_exists "${TMPDIR:-/tmp}/claude-diff-original" "original temp file should be removed after rejection" || return 1
  assert_file_not_exists "${TMPDIR:-/tmp}/claude-diff-proposed" "proposed temp file should be removed after rejection" || return 1

  rm -f "$transcript"
}

# ── Test: watcher exits cleanly on PostToolUse (acceptance) ──────

test_watcher_stops_on_acceptance() {
  open_test_diff || return 1

  local transcript
  transcript="$(mktemp /tmp/test-transcript-XXXXXX.jsonl)"
  local tool_id="toolu_ACCEPT"
  echo '{"type":"init"}' > "$transcript"

  # Start watcher
  claude_preview_watch_transcript "$transcript" "$tool_id" &
  local watcher_pid=$!
  sleep 0.5

  local t0 t1
  t0="$(now_ms)"

  # Simulate what PostToolUse does: stop watcher via stopfile, then close diff
  claude_preview_stop_transcript_watcher "$transcript" "$tool_id"
  nvim_exec "require('claude-preview.diff').close_diff()"

  wait "$watcher_pid" 2>/dev/null || true
  t1="$(now_ms)"

  report_timing "acceptance stop (stopfile+close)" "$t0" "$t1"

  assert_diff_closed "diff should be closed after acceptance" || return 1
  ! kill -0 "$watcher_pid" 2>/dev/null
  assert_eq "0" "$?" "watcher should have exited after stopfile" || return 1

  rm -f "$transcript"
}

# ── Test: watcher ignores unrelated tool_use_id in transcript ────

test_watcher_ignores_wrong_tool_id() {
  open_test_diff || return 1

  local transcript
  transcript="$(mktemp /tmp/test-transcript-XXXXXX.jsonl)"
  local tool_id="toolu_MINE"
  echo '{"type":"init"}' > "$transcript"

  # Start watcher for our tool_use_id
  claude_preview_watch_transcript "$transcript" "$tool_id" &
  local watcher_pid=$!
  sleep 0.5

  # Write rejection for a DIFFERENT tool
  make_rejection_jsonl "toolu_SOMEONE_ELSE" >> "$transcript"
  sleep 0.5

  # Diff should still be open
  assert_diff_open "diff should remain open when wrong tool_use_id is rejected" || { kill "$watcher_pid" 2>/dev/null; rm -f "$transcript"; return 1; }

  # Now write our rejection
  make_rejection_jsonl "$tool_id" >> "$transcript"
  sleep 1

  assert_diff_closed "diff should close when our tool_use_id is rejected" || { kill "$watcher_pid" 2>/dev/null; rm -f "$transcript"; return 1; }

  wait "$watcher_pid" 2>/dev/null || true
  rm -f "$transcript"
}

# ═══════════════════════════════════════════════════════════════════
# LAYER 3: Edge cases
# ═══════════════════════════════════════════════════════════════════

# ── Test: second diff replaces first, first watcher cleans up ────

test_second_diff_replaces_first_watcher() {
  local transcript
  transcript="$(mktemp /tmp/test-transcript-XXXXXX.jsonl)"
  echo '{"type":"init"}' > "$transcript"

  # Open first diff with watcher
  open_test_diff || return 1
  local tool_id_1="toolu_FIRST"
  claude_preview_watch_transcript "$transcript" "$tool_id_1" &
  local watcher_pid_1=$!
  sleep 0.3

  # Open second diff (replaces first via show_diff -> close_diff)
  local test_file2
  test_file2="$(create_test_file "src/second.lua" 'print("alpha")')"
  local orig2="${TMPDIR:-/tmp}/claude-diff-original"
  local prop2="${TMPDIR:-/tmp}/claude-diff-proposed"
  cp "$test_file2" "$orig2"
  printf '%s' 'print("beta")' > "$prop2"
  nvim_exec "require('claude-preview.diff').show_diff('$orig2', '$prop2', 'src/second.lua')"
  sleep 0.3

  assert_diff_open "second diff should be open" || { kill "$watcher_pid_1" 2>/dev/null; rm -f "$transcript"; return 1; }

  # First watcher: diff it was watching is gone (is_open still true for the new diff,
  # but the tab handle changed). The watcher checks is_open generically, so it sees
  # a diff is still open. Stopfile from PostToolUse of the first edit would clean it up.
  # For this test, simulate that stopfile.
  claude_preview_stop_transcript_watcher "$transcript" "$tool_id_1"
  wait "$watcher_pid_1" 2>/dev/null || true
  ! kill -0 "$watcher_pid_1" 2>/dev/null
  assert_eq "0" "$?" "first watcher should exit after stopfile" || return 1

  # Second watcher can now independently detect rejection
  local tool_id_2="toolu_SECOND"
  claude_preview_watch_transcript "$transcript" "$tool_id_2" &
  local watcher_pid_2=$!
  sleep 0.3

  make_rejection_jsonl "$tool_id_2" >> "$transcript"
  sleep 1

  assert_diff_closed "second diff should close on rejection" || { kill "$watcher_pid_2" 2>/dev/null; rm -f "$transcript"; return 1; }
  wait "$watcher_pid_2" 2>/dev/null || true

  rm -f "$transcript"
}

# ── Test: diff not focused when rejection arrives ────────────────

test_rejection_closes_unfocused_diff() {
  open_test_diff || return 1

  # Switch away from diff tab (back to original tab)
  nvim_exec "vim.cmd('tabfirst')"
  sleep 0.2

  # Verify we're not on the diff tab but diff is still open
  assert_diff_open "diff should be open even when not focused" || return 1

  local transcript
  transcript="$(mktemp /tmp/test-transcript-XXXXXX.jsonl)"
  local tool_id="toolu_UNFOCUSED"
  echo '{"type":"init"}' > "$transcript"

  claude_preview_watch_transcript "$transcript" "$tool_id" &
  local watcher_pid=$!
  sleep 0.3

  local t0 t1
  t0="$(now_ms)"
  make_rejection_jsonl "$tool_id" >> "$transcript"

  local tries=0
  while (( tries < 30 )); do
    local is_open
    is_open="$(nvim_eval "require('claude-preview.diff').is_open()")"
    if [[ "$is_open" == "false" ]]; then break; fi
    sleep 0.1
    tries=$((tries + 1))
  done
  t1="$(now_ms)"

  report_timing "unfocused rejection -> close" "$t0" "$t1"
  assert_diff_closed "unfocused diff should close on rejection" || { kill "$watcher_pid" 2>/dev/null; rm -f "$transcript"; return 1; }

  wait "$watcher_pid" 2>/dev/null || true
  rm -f "$transcript"
}

# ── Test: rapid accept (PostToolUse before watcher reads) ────────

test_rapid_accept_before_watcher_reads() {
  open_test_diff || return 1

  local transcript
  transcript="$(mktemp /tmp/test-transcript-XXXXXX.jsonl)"
  local tool_id="toolu_RAPID"
  echo '{"type":"init"}' > "$transcript"

  # Start watcher, give it just enough time to mkdir (but not necessarily to set up FIFO)
  claude_preview_watch_transcript "$transcript" "$tool_id" &
  local watcher_pid=$!
  sleep 0.1

  # Stop via library function only (no direct kill). This is the real production path:
  # PostToolUse fires and calls stop_transcript_watcher.
  local t0 t1
  t0="$(now_ms)"
  claude_preview_stop_transcript_watcher "$transcript" "$tool_id"

  # Also close the diff (as PostToolUse would) so the watcher's is_open check exits it
  nvim_exec "require('claude-preview.diff').close_diff()"

  # Give watcher time to notice either stopfile or diff-closed
  local tries=0
  while kill -0 "$watcher_pid" 2>/dev/null && (( tries < 30 )); do
    sleep 0.1
    tries=$((tries + 1))
  done
  t1="$(now_ms)"

  report_timing "rapid accept (stopfile + diff close)" "$t0" "$t1"

  wait "$watcher_pid" 2>/dev/null || true
  ! kill -0 "$watcher_pid" 2>/dev/null
  assert_eq "0" "$?" "watcher should exit after rapid stop" || return 1

  assert_diff_closed "diff should be closed after normal PostToolUse path" || return 1

  rm -f "$transcript"
}

# ── Test: two independent transcript watchers (multi CC session) ─

test_two_independent_watchers() {
  open_test_diff || return 1

  local transcript_a transcript_b
  transcript_a="$(mktemp /tmp/test-transcript-A-XXXXXX.jsonl)"
  transcript_b="$(mktemp /tmp/test-transcript-B-XXXXXX.jsonl)"
  echo '{"type":"init"}' > "$transcript_a"
  echo '{"type":"init"}' > "$transcript_b"

  local tool_id_a="toolu_SESSION_A"
  local tool_id_b="toolu_SESSION_B"

  # Start both watchers
  claude_preview_watch_transcript "$transcript_a" "$tool_id_a" &
  local watcher_a=$!
  claude_preview_watch_transcript "$transcript_b" "$tool_id_b" &
  local watcher_b=$!
  sleep 0.5

  # Reject session A's tool
  make_rejection_jsonl "$tool_id_a" >> "$transcript_a"
  sleep 1

  # Diff should be closed (session A's watcher closed it)
  assert_diff_closed "session A rejection should close the diff" || {
    kill "$watcher_a" "$watcher_b" 2>/dev/null
    rm -f "$transcript_a" "$transcript_b"
    return 1
  }

  # Session B's watcher should also exit (diff is no longer open)
  # Give it time to notice via its periodic is_open check
  sleep 3

  # Both watchers should be gone
  wait "$watcher_a" 2>/dev/null || true
  wait "$watcher_b" 2>/dev/null || true
  ! kill -0 "$watcher_a" 2>/dev/null
  assert_eq "0" "$?" "watcher A should have exited" || return 1
  ! kill -0 "$watcher_b" 2>/dev/null
  assert_eq "0" "$?" "watcher B should have exited" || return 1

  rm -f "$transcript_a" "$transcript_b"
}

# ── Test: watcher self-terminates when diff is manually closed ───

test_watcher_exits_on_manual_close() {
  open_test_diff || return 1

  local transcript
  transcript="$(mktemp /tmp/test-transcript-XXXXXX.jsonl)"
  local tool_id="toolu_MANUAL"
  echo '{"type":"init"}' > "$transcript"

  claude_preview_watch_transcript "$transcript" "$tool_id" &
  local watcher_pid=$!
  sleep 0.5

  # Simulate user pressing <leader>dq
  local t0 t1
  t0="$(now_ms)"
  nvim_exec "require('claude-preview.diff').close_diff_and_clear()"

  # Watcher should notice diff is gone within its 2s probe interval
  local tries=0
  while kill -0 "$watcher_pid" 2>/dev/null && (( tries < 30 )); do
    sleep 0.2
    tries=$((tries + 1))
  done
  t1="$(now_ms)"

  report_timing "manual close -> watcher exit" "$t0" "$t1"

  ! kill -0 "$watcher_pid" 2>/dev/null
  assert_eq "0" "$?" "watcher should exit when diff is manually closed" || return 1

  wait "$watcher_pid" 2>/dev/null || true
  rm -f "$transcript"
}

# ── Test: permission bypass (no transcript fields) ───────────────

test_no_transcript_fields_graceful() {
  # When CC auto-allows a tool, transcript_path/tool_use_id may be present
  # but PostToolUse fires normally. Verify that empty fields don't crash.
  local test_file
  test_file="$(create_test_file "src/bypass.lua" 'print("auto")')"

  local payload
  payload=$(cat <<EOF
{
  "tool_name": "Edit",
  "cwd": "$TEST_PROJECT_DIR",
  "transcript_path": "",
  "tool_use_id": "",
  "tool_input": {
    "file_path": "$test_file",
    "old_string": "auto",
    "new_string": "allowed",
    "replace_all": false
  }
}
EOF
)

  # This should not crash — the hook should skip watcher spawn when fields are empty
  run_pretool_hook "$payload"
  sleep 0.5

  # If a diff opened, close it
  nvim_exec "require('claude-preview.diff').close_diff()"
  sleep 0.2

  # Stop watcher should not crash either
  claude_preview_stop_transcript_watcher "" ""
  assert_eq "0" "$?" "stop_watcher with empty args should not crash" || return 1

  # No watcher state dir should have been created for empty fields
  local empty_state_dir
  empty_state_dir="$(claude_preview_watch_state_dir "" "")"
  if [[ -d "$empty_state_dir" ]]; then
    echo -e "  ${RED}FAIL: no state dir should exist for empty transcript fields${NC}" >&2
    rm -rf "$empty_state_dir"
    return 1
  fi
}

# ── Test: watcher cleanup removes all temp state ─────────────────

test_watcher_cleans_up_state() {
  local transcript
  transcript="$(mktemp /tmp/test-transcript-XXXXXX.jsonl)"
  local tool_id="toolu_CLEANUP"
  echo '{"type":"init"}' > "$transcript"

  local state_dir
  state_dir="$(claude_preview_watch_state_dir "$transcript" "$tool_id")"

  # Ensure no leftover state
  rm -rf "$state_dir"

  open_test_diff || return 1

  claude_preview_watch_transcript "$transcript" "$tool_id" &
  local watcher_pid=$!

  # Wait for state_dir to appear (watcher creates it via mkdir -p)
  local tries=0
  while [[ ! -d "$state_dir" ]] && (( tries < 20 )); do
    sleep 0.2
    tries=$((tries + 1))
  done

  if [[ ! -d "$state_dir" ]]; then
    echo -e "  ${RED}FAIL: state dir should exist while watcher runs${NC}" >&2
    kill "$watcher_pid" 2>/dev/null
    rm -f "$transcript"
    return 1
  fi

  # Kill watcher via rejection
  make_rejection_jsonl "$tool_id" >> "$transcript"
  wait "$watcher_pid" 2>/dev/null || true
  sleep 0.3

  # State dir should be cleaned up (EXIT trap removes files + rmdirs)
  if [[ -d "$state_dir" ]]; then
    echo -e "  ${RED}FAIL: state dir should be removed after watcher exits${NC}" >&2
    echo -e "    contents: $(ls -la "$state_dir" 2>/dev/null)" >&2
    rm -rf "$state_dir"
    rm -f "$transcript"
    return 1
  fi

  rm -f "$transcript"
}

# ── Test: watcher exits when tail process dies ───────────────────

test_watcher_exits_on_tail_death() {
  open_test_diff || return 1

  local transcript
  transcript="$(mktemp /tmp/test-transcript-XXXXXX.jsonl)"
  local tool_id="toolu_TAILDEATH"
  echo '{"type":"init"}' > "$transcript"

  claude_preview_watch_transcript "$transcript" "$tool_id" &
  local watcher_pid=$!
  sleep 0.5

  # Find and kill the tail process that the watcher spawned.
  # The watcher's tail is tailing our specific transcript file.
  local tail_pids
  tail_pids="$(pgrep -f "tail.*$transcript" 2>/dev/null || true)"
  if [[ -z "$tail_pids" ]]; then
    echo -e "  ${RED}FAIL: could not find tail process for watcher${NC}" >&2
    kill "$watcher_pid" 2>/dev/null
    rm -f "$transcript"
    return 1
  fi

  local t0 t1
  t0="$(now_ms)"

  # Kill the tail process
  for pid in $tail_pids; do
    kill "$pid" 2>/dev/null || true
  done

  # Watcher should notice tail died and exit
  local tries=0
  while kill -0 "$watcher_pid" 2>/dev/null && (( tries < 30 )); do
    sleep 0.2
    tries=$((tries + 1))
  done
  t1="$(now_ms)"

  report_timing "tail death -> watcher exit" "$t0" "$t1"

  wait "$watcher_pid" 2>/dev/null || true
  ! kill -0 "$watcher_pid" 2>/dev/null
  assert_eq "0" "$?" "watcher should exit when tail process dies" || return 1

  nvim_exec "require('claude-preview.diff').close_diff()"
  sleep 0.2
  rm -f "$transcript"
}

# ═══════════════════════════════════════════════════════════════════
# Run all tests
# ═══════════════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}── Layer 1: Pure bash (no nvim) ──${NC}"
run_test "rejection line detection (positive)"      test_line_is_rejection_positive
run_test "rejection line detection (wrong id)"       test_line_is_rejection_wrong_id
run_test "rejection line detection (acceptance)"     test_line_is_rejection_acceptance
run_test "rejection line detection (unrelated tool)" test_line_is_rejection_unrelated
run_test "rejection line detection (garbage)"        test_line_is_rejection_garbage
run_test "state dir lifecycle"                       test_state_dir_lifecycle
run_test "stop watcher (no-op)"                      test_stop_watcher_noop
run_test "watcher stops on stopfile"                 test_watcher_stops_on_stopfile
run_test "is_open shell function (live socket)"      test_nvim_diff_is_open_live_socket
run_test "is_open shell function (dead socket)"      test_nvim_diff_is_open_dead_socket
run_test "is_open shell function (no socket)"        test_nvim_diff_is_open_no_socket

echo ""
echo -e "${YELLOW}── Layer 2: Headless nvim integration ──${NC}"
run_test "diff tab lifecycle"                        test_diff_tab_lifecycle
run_test "diff buffers are scratch (all nofile)"     test_diff_buffers_are_scratch
run_test "watcher closes diff on rejection"          test_watcher_closes_diff_on_rejection
run_test "watcher stops on acceptance"               test_watcher_stops_on_acceptance
run_test "watcher ignores wrong tool_use_id"         test_watcher_ignores_wrong_tool_id

echo ""
echo -e "${YELLOW}── Layer 3: Edge cases ──${NC}"
run_test "second diff replaces first watcher"        test_second_diff_replaces_first_watcher
run_test "rejection closes unfocused diff"           test_rejection_closes_unfocused_diff
run_test "rapid accept (stopfile only, no kill)"     test_rapid_accept_before_watcher_reads
run_test "two independent watchers (multi session)"  test_two_independent_watchers
run_test "watcher exits on manual close"             test_watcher_exits_on_manual_close
run_test "watcher exits on tail death"               test_watcher_exits_on_tail_death
run_test "no transcript fields (permission bypass)"  test_no_transcript_fields_graceful
run_test "watcher cleans up state"                   test_watcher_cleans_up_state

# ── Teardown ─────────────────────────────────────────────────────

stop_nvim
cleanup_test_project
