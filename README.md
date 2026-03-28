# claude-preview.nvim

A Neovim plugin that shows a **diff preview before Claude Code applies any file change** — letting you review exactly what's changing before accepting

Designed for the workflow of running Claude Code CLI in an external terminal alongside Neovim.

---

## Demo

![claude-preview.nvim demo](docs/claude-preview-demo.gif)

---

## How it works

```
Claude CLI (terminal)                                Neovim
        │                                              │
   Proposes an Edit                                    │
        │                                              │
   PreToolUse hook fires ──→ hook script ──→ RPC → show_diff()
        │                                              │ (new tab, side-by-side)
   CLI: "Accept? (y/n)"                                │
        │                                       User reviews diff
   User accepts/rejects                                │
        │                                              │
   PostToolUse hook fires ─→ hook script ──→ RPC → close_diff()
```

Three mechanisms:

1. **Claude Code Hooks** — `PreToolUse` intercepts edits, `PostToolUse` cleans up
2. **Neovim RPC** — hook scripts send Lua commands via `nvim --server <socket> --remote-send`
3. **Neovim diff mode** — native side-by-side diff in a dedicated tab, or GitHub-style inline diff

---

## Requirements

- Neovim ≥ 0.9
- [jq](https://jqlang.github.io/jq/) — for JSON parsing in hook scripts
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) with hooks support

No Python dependency — file transformations use `nvim --headless -l`.

---

## Installation

### lazy.nvim

```lua
{
  "Cannon07/claude-preview.nvim",
  config = function()
    require("claude-preview").setup()
  end,
}
```

### Manual (path-based)

```lua
vim.opt.rtp:prepend("/path/to/claude-preview.nvim")
require("claude-preview").setup()
```

---

## Quick Start

1. Install the plugin and call `setup()` (see above)
2. Open a project in Neovim
3. Run `:ClaudePreviewInstallHooks` — writes hooks to `.claude/settings.local.json`
4. Restart Claude Code CLI in the project directory
5. Ask Claude to edit a file — a diff tab opens automatically in Neovim
6. Accept/reject in the CLI; if accepted the tab closes automatically
7. If rejected, press `<leader>dq` in Neovim to close the tab

---

## Configuration

All options with defaults:

```lua
require("claude-preview").setup({
  diff = {
    layout   = "tab",    -- "tab" (new tab) | "vsplit" (current tab) | "inline" (GitHub-style)
    labels   = { current = "CURRENT", proposed = "PROPOSED" },
    auto_close = true,   -- close diff after accept
    equalize   = true,   -- 50/50 split widths (tab/vsplit only)
    full_file  = true,   -- show full file, not just diff hunks (tab/vsplit only)
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
| `:ClaudePreviewInstallHooks` | Write PreToolUse/PostToolUse hooks to `.claude/settings.local.json` |
| `:ClaudePreviewUninstallHooks` | Remove claude-preview hooks (leaves other hooks intact) |
| `:ClaudePreviewCloseDiff` | Manually close the diff tab (use after rejecting a change) |
| `:ClaudePreviewStatus` | Show socket path, hook status, and dependency check |
| `:checkhealth claude-preview` | Full health check |

## Keymaps

| Key | Description |
|-----|-------------|
| `<leader>dq` | Close the diff tab (same as `:ClaudePreviewCloseDiff`) |

---

## Diff Layouts

claude-preview supports three diff layouts, configured via `diff.layout`:

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
require("claude-preview").setup({
  diff = { layout = "inline" },
})
```

---

## Neo-tree Integration (Optional)

If you use [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim), claude-preview will automatically decorate your file tree with visual indicators when Claude proposes changes. No extra configuration is required — it works out of the box.

![neo-tree integration demo](docs/claude-preview-neotree-integration.gif)

### What you get

| Status | Icon | Name Color | Description |
|--------|------|------------|-------------|
| Modified | 󰏫 | Orange | Claude is editing an existing file |
| Created | 󰎔 | Cyan + italic | Claude is creating a new file (shown as a virtual node) |
| Deleted | 󰆴 | Red + strikethrough | Claude is deleting a file via `rm` |

Additional behaviors:

- **Auto-reveal** — the tree expands to highlight the changed file
- **Virtual nodes** — new files/directories appear in the tree before they exist on disk
- **Clean focus** — git status, diagnostics, and modified indicators are temporarily hidden while changes are pending
- **Auto-cleanup** — all indicators clear when you accept, reject, or press `<leader>dq`

### Neo-tree configuration options

All neo-tree options with defaults:

```lua
require("claude-preview").setup({
  neo_tree = {
    enabled = true,             -- set false to disable neo-tree integration
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
claude-preview.nvim/
├── lua/claude-preview/
│   ├── init.lua        setup(), config, commands
│   ├── diff.lua        show_diff(), close_diff()
│   ├── hooks.lua       install/uninstall .claude/settings.local.json
│   ├── changes.lua     change status registry (modified/created/deleted)
│   ├── neo_tree.lua    neo-tree integration (icons, virtual nodes, reveal)
│   └── health.lua      :checkhealth
└── bin/
    ├── claude-preview-diff.sh   PreToolUse hook entry point
    ├── claude-close-diff.sh     PostToolUse hook entry point
    ├── nvim-socket.sh           Neovim socket discovery
    ├── nvim-send.sh             RPC send helper
    ├── apply-edit.lua           Single Edit transformer (nvim --headless -l)
    └── apply-multi-edit.lua     MultiEdit transformer (nvim --headless -l)
```

---

## Recommended companion settings

For buffers to auto-reload after Claude writes a file, add this to your Neovim config:

```lua
vim.o.autoread = true
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
 callback = function()
  if vim.fn.getcmdwintype() == "" then
   vim.cmd("checktime")
  end
 end,
})
```

---

## Troubleshooting

**Diff doesn't open**

- Run `:ClaudePreviewStatus` — check that `Neovim socket` is found
- Ensure `jq` is in PATH
- Restart Claude Code after installing hooks (hooks are read at startup)

**Hooks not firing**

- Run `:ClaudePreviewInstallHooks` in the project root
- Verify `.claude/settings.local.json` contains the hook entries
- Restart the Claude CLI

**Diff doesn't close after rejecting**

- Press `<leader>dq` or run `:ClaudePreviewCloseDiff` — PostToolUse only fires on accept

---

## License

MIT — see [LICENSE](LICENSE)
