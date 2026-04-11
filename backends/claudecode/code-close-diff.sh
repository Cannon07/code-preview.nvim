#!/usr/bin/env bash
# code-close-diff.sh — PostToolUse hook adapter for Claude Code
# Delegates to core-post-tool.sh with the Claude Code backend flag.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"
export CODE_PREVIEW_BACKEND="claudecode"
exec "$BIN_DIR/core-post-tool.sh"
