#!/usr/bin/env bash
# code-preview-diff.sh — PreToolUse hook adapter for Claude Code
# Delegates to core-pre-tool.sh with the Claude Code backend flag.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"
export CODE_PREVIEW_BACKEND="claudecode"
exec "$BIN_DIR/core-pre-tool.sh"
