#!/usr/bin/env bash
# run.sh — Main test runner for claude-preview.nvim E2E tests
#
# Usage:
#   ./tests/run.sh                      # run all tests (plugin + backends)
#   ./tests/run.sh plugin               # run core plugin tests (plenary)
#   ./tests/run.sh backends             # run all backend tests
#   ./tests/run.sh backends/claude      # run Claude Code backend tests only
#   ./tests/run.sh backends/opencode    # run OpenCode backend tests only
#   ./tests/run.sh edit                 # run any backend test file matching "edit"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# ── Dependency checks ────────────────────────────────────────────

check_deps() {
  local missing=()
  command -v nvim  >/dev/null 2>&1 || missing+=("nvim")
  command -v jq    >/dev/null 2>&1 || missing+=("jq")

  if (( ${#missing[@]} > 0 )); then
    echo -e "${RED}Missing dependencies: ${missing[*]}${NC}" >&2
    exit 1
  fi

  local nvim_version
  nvim_version="$(nvim --version | head -1 | grep -oE '[0-9]+\.[0-9]+')"
  echo -e "${CYAN}Neovim version: $nvim_version${NC}"
}

# ── Discover backend test files ─────────────────────────────────

discover_backend_tests() {
  local filter="${1:-all}"
  local test_files=()

  case "$filter" in
    backends)
      while IFS= read -r f; do
        test_files+=("$f")
      done < <(find "$SCRIPT_DIR/backends" -name 'test_*.sh' -type f 2>/dev/null | sort)
      ;;
    backends/*)
      local backend_dir="$SCRIPT_DIR/$filter"
      if [[ -d "$backend_dir" ]]; then
        while IFS= read -r f; do
          test_files+=("$f")
        done < <(find "$backend_dir" -name 'test_*.sh' -type f 2>/dev/null | sort)
      fi
      ;;
    *)
      # Fuzzy match: find any test file whose name contains the filter
      while IFS= read -r f; do
        local base
        base="$(basename "$f")"
        if [[ "$base" == *"$filter"* ]]; then
          test_files+=("$f")
        fi
      done < <(find "$SCRIPT_DIR/backends" -name 'test_*.sh' -type f 2>/dev/null | sort)
      ;;
  esac

  printf '%s\n' "${test_files[@]}"
}

# Format a test file path as a readable label
test_label() {
  local file="$1"
  echo "${file#"$SCRIPT_DIR/"}"
}

# ── Run plenary plugin tests ────────────────────────────────────

run_plugin_tests() {
  echo ""
  echo -e "${YELLOW}── Plugin Tests (plenary busted) ──${NC}"
  echo ""
  bash "$SCRIPT_DIR/run_lua.sh"
}

# ── Run backend shell tests ─────────────────────────────────────

run_backend_tests() {
  local filter="${1:-backends}"

  local test_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && test_files+=("$f")
  done < <(discover_backend_tests "$filter")

  if (( ${#test_files[@]} == 0 )); then
    echo -e "${YELLOW}No backend test files matched filter: $filter${NC}"
    return 1
  fi

  echo ""
  echo -e "${YELLOW}── Backend Tests (shell) ──${NC}"
  echo ""
  echo -e "Running ${#test_files[@]} test file(s)..."
  echo ""

  for test_file in "${test_files[@]}"; do
    echo -e "${YELLOW}── $(test_label "$test_file") ──${NC}"
    source "$test_file"
    echo ""
  done
}

# ── Main ─────────────────────────────────────────────────────────

main() {
  local filter="${1:-all}"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${CYAN}claude-preview.nvim E2E Test Suite${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  check_deps

  case "$filter" in
    all)
      run_plugin_tests
      echo ""
      run_backend_tests "backends"
      ;;
    plugin)
      run_plugin_tests
      ;;
    backends|backends/*)
      run_backend_tests "$filter"
      ;;
    *)
      # Fuzzy match — only searches backend tests
      run_backend_tests "$filter"
      ;;
  esac

  # Print shell test summary (plenary prints its own)
  if [[ "$filter" != "plugin" ]]; then
    print_summary
  fi
}

main "$@"
