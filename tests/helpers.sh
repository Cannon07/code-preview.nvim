#!/usr/bin/env bash
# helpers.sh — Shared test utilities for claude-preview.nvim E2E tests
#
# Provides:
#   start_nvim        — launch headless Neovim with the plugin on a known socket
#   stop_nvim         — kill the headless Neovim and clean up
#   nvim_eval         — evaluate a Lua expression in the running Neovim, print result
#   nvim_exec         — execute a Lua statement in the running Neovim (no output)
#   assert_eq         — compare two values, fail with message if different
#   assert_contains   — check a string contains a substring
#   assert_file_exists — check a file exists
#   create_test_file  — write content to a file in the test project directory
#   pass / fail       — report test result

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_SOCKET="/tmp/claude-preview-test-nvim.sock"
TEST_PROJECT_DIR=""
NVIM_PID=""

# ── Colors ───────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ── Counters ─────────────────────────────────────────────────────

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# ── Test project setup ───────────────────────────────────────────

setup_test_project() {
  TEST_PROJECT_DIR="$(mktemp -d /tmp/claude-preview-test-project.XXXXXX)"
  mkdir -p "$TEST_PROJECT_DIR"
}

cleanup_test_project() {
  if [[ -n "$TEST_PROJECT_DIR" && -d "$TEST_PROJECT_DIR" ]]; then
    rm -rf "$TEST_PROJECT_DIR"
  fi
  TEST_PROJECT_DIR=""
}

# ── Create a file in the test project ────────────────────────────

create_test_file() {
  local relpath="$1"
  local content="$2"
  local fullpath="$TEST_PROJECT_DIR/$relpath"
  mkdir -p "$(dirname "$fullpath")"
  printf '%s' "$content" > "$fullpath"
  echo "$fullpath"
}

# ── Neovim lifecycle ─────────────────────────────────────────────

start_nvim() {
  # Clean up any leftover socket
  rm -f "$TEST_SOCKET"

  # Start headless Neovim with the plugin in the runtime path
  # Use --clean to avoid user config interference
  nvim --headless --clean \
    --cmd "set rtp+=$REPO_ROOT" \
    --listen "$TEST_SOCKET" \
    -c "lua require('claude-preview').setup()" \
    &>/dev/null &
  NVIM_PID=$!

  # Wait for socket to appear (up to 5 seconds)
  local tries=0
  while [[ ! -S "$TEST_SOCKET" ]] && (( tries < 50 )); do
    sleep 0.1
    tries=$((tries + 1))
  done

  if [[ ! -S "$TEST_SOCKET" ]]; then
    echo -e "${RED}FATAL: Neovim failed to start (socket not created)${NC}" >&2
    return 1
  fi

  # Verify it responds
  if ! nvim --server "$TEST_SOCKET" --remote-expr "1" >/dev/null 2>&1; then
    echo -e "${RED}FATAL: Neovim started but socket not responsive${NC}" >&2
    return 1
  fi
}

stop_nvim() {
  if [[ -n "$NVIM_PID" ]] && kill -0 "$NVIM_PID" 2>/dev/null; then
    # Graceful quit
    nvim --server "$TEST_SOCKET" --remote-expr "execute('qall!')" >/dev/null 2>&1 || true
    sleep 0.2
    # Force kill if still alive
    kill -0 "$NVIM_PID" 2>/dev/null && kill -9 "$NVIM_PID" 2>/dev/null || true
  fi
  rm -f "$TEST_SOCKET"
  NVIM_PID=""
}

# ── RPC helpers ──────────────────────────────────────────────────

# Evaluate a Lua expression and return the result as a string
nvim_eval() {
  local lua_expr="$1"
  local tmp_lua
  local tmp_out
  tmp_lua="$(mktemp /tmp/claude-preview-test-eval.XXXXXX.lua)"
  tmp_out="/tmp/claude-preview-test-eval-out.$$"

  # Write Lua code that evaluates the expression and writes result to a temp file
  printf 'local __result = %s\nlocal __f = io.open("%s", "w")\n__f:write(tostring(__result))\n__f:close()' "$lua_expr" "$tmp_out" > "$tmp_lua"

  # Execute the Lua file
  nvim --server "$TEST_SOCKET" --remote-expr "execute('luafile $tmp_lua')" >/dev/null 2>&1

  # Read the result from the temp file
  local result=""
  if [[ -f "$tmp_out" ]]; then
    result="$(cat "$tmp_out")"
    rm -f "$tmp_out"
  fi
  rm -f "$tmp_lua"

  echo "$result"
}

# Execute a Lua statement (no return value needed)
nvim_exec() {
  local lua_cmd="$1"
  local tmp_lua
  tmp_lua="$(mktemp /tmp/claude-preview-test-exec.XXXXXX.lua)"
  printf '%s' "$lua_cmd" > "$tmp_lua"
  nvim --server "$TEST_SOCKET" --remote-expr "execute('luafile $tmp_lua')" >/dev/null 2>&1
  local rc=$?
  rm -f "$tmp_lua"
  return $rc
}

# ── Assertions ───────────────────────────────────────────────────

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-"expected '$expected', got '$actual'"}"
  if [[ "$expected" != "$actual" ]]; then
    echo -e "  ${RED}FAIL: $msg${NC}" >&2
    echo -e "    expected: ${CYAN}$expected${NC}" >&2
    echo -e "    actual:   ${CYAN}$actual${NC}" >&2
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-"expected output to contain '$needle'"}"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${RED}FAIL: $msg${NC}" >&2
    echo -e "    output: ${CYAN}$haystack${NC}" >&2
    echo -e "    needle: ${CYAN}$needle${NC}" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-"expected output NOT to contain '$needle'"}"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${RED}FAIL: $msg${NC}" >&2
    echo -e "    output: ${CYAN}$haystack${NC}" >&2
    return 1
  fi
}

assert_file_exists() {
  local path="$1"
  local msg="${2:-"expected file to exist: $path"}"
  if [[ ! -f "$path" ]]; then
    echo -e "  ${RED}FAIL: $msg${NC}" >&2
    return 1
  fi
}

assert_file_not_exists() {
  local path="$1"
  local msg="${2:-"expected file NOT to exist: $path"}"
  if [[ -f "$path" ]]; then
    echo -e "  ${RED}FAIL: $msg${NC}" >&2
    return 1
  fi
}

# ── Test reporting ───────────────────────────────────────────────

run_test() {
  local test_name="$1"
  local test_func="$2"
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  echo -e "${CYAN}  ▶ $test_name${NC}"
  if $test_func; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}✓ $test_name${NC}"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}✗ $test_name${NC}"
  fi
}

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if (( TESTS_FAILED == 0 )); then
    echo -e "${GREEN}All $TESTS_TOTAL tests passed.${NC}"
  else
    echo -e "${RED}$TESTS_FAILED/$TESTS_TOTAL tests failed.${NC}"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  return $TESTS_FAILED
}

# ── Hook script helpers ──────────────────────────────────────────

# Run the PreToolUse hook script with a JSON payload and a specific socket.
# Returns the hook's stdout (JSON response). Use in $() to capture, or
# redirect to /dev/null if you don't need the output.
run_pretool_hook() {
  local json_payload="$1"
  echo "$json_payload" | \
    NVIM_LISTEN_ADDRESS="$TEST_SOCKET" \
    bash "$REPO_ROOT/bin/claude-preview-diff.sh" 2>/dev/null || true
}

# Run the PostToolUse hook script with a JSON payload
run_posttool_hook() {
  local json_payload="$1"
  echo "$json_payload" | \
    NVIM_LISTEN_ADDRESS="$TEST_SOCKET" \
    bash "$REPO_ROOT/bin/claude-close-diff.sh" 2>/dev/null || true
}
