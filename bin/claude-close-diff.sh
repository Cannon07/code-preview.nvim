#!/usr/bin/env bash
# claude-close-diff.sh — PostToolUse hook adapter for Claude Code
# Delegates to core-post-tool.sh with the Claude backend flag.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export CLAUDE_PREVIEW_BACKEND="claude"
exec "$SCRIPT_DIR/core-post-tool.sh"
