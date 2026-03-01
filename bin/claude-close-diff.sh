#!/usr/bin/env bash
# claude-close-diff.sh — PostToolUse hook for Claude Code
# Closes the diff preview tab in Neovim after the user accepts or rejects.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read stdin (PostToolUse sends JSON but we don't need it)
cat > /dev/null

# Discover Neovim socket and load RPC helpers
source "$SCRIPT_DIR/nvim-socket.sh" 2>/dev/null
source "$SCRIPT_DIR/nvim-send.sh"

# Close the diff tab in Neovim (silently skip if no socket)
nvim_send "require('claude-preview.diff').close_diff()" || true

# Clean up temp files
rm -f "${TMPDIR:-/tmp}/claude-diff-original" "${TMPDIR:-/tmp}/claude-diff-proposed"

exit 0
