#!/usr/bin/env bash
# claude-preview-diff.sh — PreToolUse hook adapter for Claude Code
# Delegates to core-pre-tool.sh with the Claude backend flag.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export CLAUDE_PREVIEW_BACKEND="claude"
exec "$SCRIPT_DIR/core-pre-tool.sh"
