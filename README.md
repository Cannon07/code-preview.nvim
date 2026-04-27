# code-preview.nvim

A Neovim plugin that shows a **diff preview before your AI coding agent applies any file change** — letting you review exactly what's changing before accepting.

Supports [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [OpenCode](https://opencode.ai), and [GitHub Copilot CLI](https://github.com/github/copilot-cli) as backends.

---

## Demo

### Claude Code
![Claude Code demo](docs/code-preview-claudecode.gif)

### OpenCode
![OpenCode demo](docs/code-preview-opencode.gif)

### GitHub Copilot CLI
![GitHub Copilot CLI demo](docs/code-preview-copilot.gif)

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
  - [Claude Code](#claude-code)
  - [OpenCode](#opencode)
  - [GitHub Copilot CLI](#github-copilot-cli)
- [How it works](#how-it-works)
- [Configuration](#configuration)
- [Commands](#commands)
- [Diff Layouts](#diff-layouts)
- [Neo-tree Integration](#neo-tree-integration-optional)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)

---

## Features

- **Diff preview** — side-by-side or inline diff opens in Neovim before any file is written
- **Multiple layouts** — tab, vsplit, or GitHub-style inline diff with syntax highlighting
- **Neo-tree integration** — file tree indicators show which files are being modified, created, or deleted
- **Multi-backend** — works with Claude Code CLI and OpenCode
- **No Python dependency** — file transformations use `nvim --headless -l`

---

## Requirements

- Neovim >= 0.9

**For Claude Code backend:**
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) with hooks support
- [jq](https://jqlang.github.io/jq/) — for JSON parsing in hook scripts

**For OpenCode backend:**
- [OpenCode](https://opencode.ai) >= 1.3.0

**For GitHub Copilot CLI backend:**
- [GitHub Copilot CLI](https://github.com/github/copilot-cli) (generally available since Feb 2026)
- [jq](https://jqlang.github.io/jq/) — for hook payload translation

---

## Installation

### lazy.nvim

```lua
{
  "Cannon07/code-preview.nvim",
  config = function()
    require("code-preview").setup()
  end,
}
```

### Manual (path-based)

```lua
vim.opt.rtp:prepend("/path/to/code-preview.nvim")
require("code-preview").setup()
```

---

## Quick Start

### Claude Code

1. Install the plugin and call `setup()`
2. Open a project in Neovim
3. Run `:CodePreviewInstallClaudeCodeHooks` — writes hooks to `.claude/settings.local.json`
4. Restart Claude Code CLI in the project directory
5. Ask Claude to edit a file — a diff opens automatically in Neovim
6. Accept/reject in the CLI; the diff closes automatically on accept
7. If rejected, press `<leader>dq` to close the diff manually

### OpenCode

1. Install the plugin and call `setup()`
2. Open a project in Neovim
3. Run `:CodePreviewInstallOpenCodeHooks` — copies the plugin to `.opencode/plugins/`
4. Ensure your OpenCode config (`~/.config/opencode/opencode.json`) has permission prompts enabled:
   ```json
   {
     "permission": {
       "edit": "ask",
       "bash": "ask"
     }
   }
   ```
5. Start OpenCode in the project directory
6. Ask OpenCode to edit a file — a diff opens automatically in Neovim
7. Accept/reject in OpenCode; the diff closes automatically on accept
8. If rejected, press `<leader>dq` to close the diff manually

### GitHub Copilot CLI

1. Install the plugin and call `setup()`
2. Open a project in Neovim
3. Run `:CodePreviewInstallCopilotCliHooks` — writes `.github/hooks/code-preview.json`
4. Start Copilot CLI in the project directory
5. Ask Copilot to edit a file — a diff opens automatically in Neovim
6. Accept/reject in the CLI; the diff closes automatically on accept
7. If rejected, press `<leader>dq` to close the diff manually

> **Note:** Copilot CLI does not fire post-tool hooks on rejection, so rejected diffs remain open until you dismiss them (same as Claude Code).

---

## How it works

```
AI Agent (terminal)                              Neovim
        |                                          |
   Proposes an Edit                                |
        |                                          |
   Hook/plugin fires ──→ compute diff ──→ RPC → show_diff()
        |                                          | (side-by-side or inline)
   CLI: "Accept? (y/n)"                            |
        |                                     User reviews diff
   User accepts/rejects                            |
        |                                          |
   Post hook fires ────→ cleanup ─────→ RPC → close_diff()
```

**Claude Code** uses shell-based hooks (`PreToolUse`/`PostToolUse`) configured in `.claude/settings.local.json`.

**OpenCode** uses a TypeScript plugin (`tool.execute.before`/`tool.execute.after`) loaded from `.opencode/plugins/`.

**GitHub Copilot CLI** uses shell-based hooks (`preToolUse`/`postToolUse`) configured in `.github/hooks/code-preview.json`. The adapter translates Copilot's tool vocabulary (`apply_patch`, `edit`, `create`, `bash`) into the same normalized format used by the other backends.

All backends communicate with Neovim via RPC (`nvim --server <socket> --remote-send`).

---

## Configuration

All options with defaults:

```lua
require("code-preview").setup({
  debug = false,         -- enable debug logging to stdpath("log")/code-preview.log
  diff = {
    layout   = "tab",    -- "tab" (new tab) | "vsplit" (current tab) | "inline" (GitHub-style)
    labels   = { current = "CURRENT", proposed = "PROPOSED" },
    equalize   = true,   -- 50/50 split widths (tab/vsplit only)
    full_file  = true,   -- show full file, not just diff hunks (tab/vsplit only)
    visible_only = false, -- skip diffs for files not open in any Neovim buffer
    defer_claude_permissions = false, -- for Claude Code: let its own settings decide, don't prompt
  },
  highlights = {
    current = {          -- CURRENT (original) side — tab/vsplit layouts
      DiffAdd    = { bg = "#4c2e2e" },
      DiffDelete = { bg = "#4c2e2e" },
      DiffChange = { bg = "#4c3a2e" },
      DiffText   = { bg = "#5c3030" },
    },
    proposed = {         -- PROPOSED side — tab/vsplit layouts
      DiffAdd    = { bg = "#2e4c2e" },
      DiffDelete = { bg = "#4c2e2e" },
      DiffChange = { bg = "#2e3c4c" },
      DiffText   = { bg = "#3e5c3e" },
    },
    inline = {           -- inline layout
      added        = { bg = "#2e4c2e" },          -- added line background
      removed      = { bg = "#4c2e2e" },          -- removed line background
      added_text   = { bg = "#3a6e3a" },          -- changed characters (added)
      removed_text = { bg = "#6e3a3a" },          -- changed characters (removed)
    },
  },
})
```

---

## Commands

| Command | Description |
|---------|-------------|
| `:CodePreviewInstallClaudeCodeHooks` | Install Claude Code hooks to `.claude/settings.local.json` |
| `:CodePreviewUninstallClaudeCodeHooks` | Remove Claude Code hooks (leaves other hooks intact) |
| `:CodePreviewInstallOpenCodeHooks` | Install OpenCode plugin to `.opencode/plugins/` |
| `:CodePreviewUninstallOpenCodeHooks` | Remove OpenCode plugin |
| `:CodePreviewInstallCopilotCliHooks` | Install Copilot CLI hooks to `.github/hooks/code-preview.json` |
| `:CodePreviewUninstallCopilotCliHooks` | Remove Copilot CLI hooks |
| `:CodePreviewCloseDiff` | Manually close the diff (use after rejecting a change) |
| `:CodePreviewStatus` | Show socket path, hook status, and dependency check |
| `:CodePreviewToggleVisibleOnly` | Toggle visible_only — show diffs only for open buffers |
| `:checkhealth code-preview` | Full health check (both backends) |

> **Migrating?** The old `:ClaudePreview*` commands still work but show a deprecation warning. They will be removed in a future release.

## Keymaps

| Key | Scope | Description |
|-----|-------|-------------|
| `<leader>dq` | global | Close the diff (same as `:CodePreviewCloseDiff`) |
| `]c` | inline diff buffer | Jump to next change |
| `[c` | inline diff buffer | Jump to previous change |

All defaults are configurable via `setup()`:

```lua
require("code-preview").setup({
  keys = {
    next_change = "]c",          -- inline diff: next change
    prev_change = "[c",          -- inline diff: previous change
    close_all   = "<leader>dq",  -- close diff and clear indicators
  },
})
```

Set any entry to `false` to skip that binding, or `keys = false` to skip them all. A `<Plug>(CodePreviewCloseAll)` mapping is always defined, so you can bind it yourself even with `keys = false`:

```lua
vim.keymap.set("n", "<leader>x", "<Plug>(CodePreviewCloseAll)")
```

---

## Diff Layouts

code-preview supports three diff layouts, configured via `diff.layout`:

| Layout | Description |
|--------|-------------|
| `"tab"` (default) | Side-by-side diff in a new tab — CURRENT on the left, PROPOSED on the right |
| `"vsplit"` | Side-by-side diff as a vertical split in the current tab |
| `"inline"` | GitHub-style unified diff in a single buffer with syntax highlighting preserved |

### Inline diff features

- **Syntax highlighting** — the file's language highlighting is preserved
- **Character-level diffs** — changed portions within a line are highlighted with a brighter background
- **Sign column** — `+`/`-` signs indicate added/removed lines
- **Navigation** — `]c` / `[c` to jump between changes

To use inline diff:

```lua
require("code-preview").setup({
  diff = { layout = "inline" },
})
```

---

## Neo-tree Integration (Optional)

If you use [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim), code-preview will automatically decorate your file tree with visual indicators when changes are proposed. No extra configuration is required — it works out of the box.

![neo-tree integration demo](docs/code-preview-neotree-integration.gif)

### What you get

| Status | Icon | Name Color | Description |
|--------|------|------------|-------------|
| Modified | 󰏫 | Orange | An existing file is being edited |
| Created | 󰎔 | Cyan + italic | A new file is being created (shown as a virtual node) |
| Deleted | 󰆴 | Red + strikethrough | A file is being deleted via `rm` |

Additional behaviors:
- **Auto-reveal** — the tree expands to highlight the changed file
- **Virtual nodes** — new files/directories appear in the tree before they exist on disk
- **Clean focus** — git status, diagnostics, and modified indicators are temporarily hidden while changes are pending
- **Auto-cleanup** — all indicators clear when you accept, reject, or press `<leader>dq`

### Neo-tree configuration options

All neo-tree options with defaults:

```lua
require("code-preview").setup({
  neo_tree = {
    enabled = true,             -- set false to disable neo-tree integration
    reveal = true,              -- auto-reveal changed files in the tree
    reveal_root = "cwd",        -- "cwd" (current working dir) or "git" (git root)
    position = "right",         -- neo-tree window position: "left", "right", "float"
    symbols = {
      modified = "󰏫",
      created  = "󰎔",
      deleted  = "󰆴",
    },
    highlights = {
      modified = { fg = "#e8a838", bold = true },
      created  = { fg = "#56c8d8", bold = true },
      deleted  = { fg = "#e06c75", bold = true, strikethrough = true },
    },
  },
})
```

> **Note:** Neo-tree is a soft dependency. If neo-tree is not installed, the plugin works exactly as before — only the diff preview.

---

## Architecture

```
code-preview.nvim/
├── lua/code-preview/
│   ├── init.lua                     setup(), config, commands
│   ├── diff.lua                     show_diff(), close_diff()
│   ├── log.lua                      opt-in debug logging
│   ├── changes.lua                  change status registry (modified/created/deleted)
│   ├── neo_tree.lua                 neo-tree integration (icons, virtual nodes, reveal)
│   ├── health.lua                   :checkhealth (both backends)
│   └── backends/
│       ├── claudecode.lua           Claude Code hook install/uninstall
│       └── opencode.lua             OpenCode plugin install/uninstall
├── bin/                             Shared core scripts
│   ├── core-pre-tool.sh             Unified PreToolUse logic
│   ├── core-post-tool.sh            Unified PostToolUse logic
│   ├── nvim-socket.sh               Neovim socket discovery
│   ├── nvim-send.sh                 RPC send helper
│   ├── apply-edit.lua               Single Edit transformer
│   ├── apply-multi-edit.lua         MultiEdit transformer
│   └── apply-patch.lua              ApplyPatch transformer (custom patch format)
├── backends/
│   ├── claudecode/                  Claude Code adapter
│   │   ├── code-preview-diff.sh     PreToolUse hook entry point
│   │   └── code-close-diff.sh       PostToolUse hook entry point
│   ├── opencode/                    OpenCode adapter
│   │   ├── index.ts                 tool.execute.before/after hooks
│   │   ├── package.json
│   │   └── tsconfig.json
│   └── copilot/                     GitHub Copilot CLI adapter
│       ├── code-preview-diff.sh     preToolUse hook — translates Copilot JSON → core
│       └── code-close-diff.sh       postToolUse hook — same for close
```

---

## Testing

The test suite uses [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) for core plugin tests and shell scripts for backend integration tests. CI runs on both Ubuntu and macOS.

```bash
./tests/run.sh                          # all tests (plugin + backends)
./tests/run.sh plugin                   # core plugin tests only (plenary busted)
./tests/run.sh backends                 # all backend integration tests
./tests/run.sh backends/claudecode      # Claude Code backend only
./tests/run.sh backends/opencode        # OpenCode backend only
```

**Dependencies:** Neovim >= 0.10, jq, bun (for OpenCode tests). Plenary is auto-installed to `deps/` on first run.

---

## Recommended companion settings

For buffers to auto-reload after a file is written, add this to your Neovim config:

```lua
vim.o.autoread = true
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
  command = "checktime",
})
```
---

## Troubleshooting

**Diff doesn't open**
- Run `:CodePreviewStatus` — check that `Neovim socket` is found
- Run `:checkhealth code-preview` — check for missing dependencies
- Enable debug logging (`debug = true` in setup) and check `~/.local/state/nvim/code-preview.log`
- Restart the CLI agent after installing hooks (hooks are read at startup)

**Claude Code hooks not firing**
- Run `:CodePreviewInstallClaudeCodeHooks` in the project root
- Verify `.claude/settings.local.json` contains the hook entries
- Ensure `jq` is in PATH
- Restart Claude Code CLI

**OpenCode plugin not loading**
- Run `:CodePreviewInstallOpenCodeHooks` in the project root
- Verify `.opencode/plugins/index.ts` exists
- Ensure `"permission": { "edit": "ask" }` is set in `~/.config/opencode/opencode.json`
- Restart OpenCode

**Copilot CLI hooks not firing**
- Run `:CodePreviewInstallCopilotCliHooks` in the project root
- Verify `.github/hooks/code-preview.json` exists
- Ensure `jq` is in PATH
- Restart Copilot CLI (hooks are loaded at session start)

**Diff doesn't close after rejecting**
- Press `<leader>dq` or run `:CodePreviewCloseDiff` — the post hook only fires on accept

**Migrating from older versions**
- Update `require("claude-preview")` to `require("code-preview")` in your Neovim config
- Re-run `:CodePreviewInstallClaudeCodeHooks` to update hook paths
- The old `:ClaudePreview*` commands still work but show deprecation warnings

---

## License

MIT — see [LICENSE](LICENSE)
