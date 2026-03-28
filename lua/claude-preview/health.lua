local M = {}

function M.check()
  -- vim.health API differs between Neovim 0.9 and 0.10+
  local h = vim.health or require("health")
  local ok    = h.ok    or h.report_ok
  local warn  = h.warn  or h.report_warn
  local error = h.error or h.report_error
  local start = h.start or h.report_start

  -- ── Common ────────────────────────────────────────────────────

  start("claude-preview.nvim")

  -- Neovim RPC socket (required for both backends)
  local socket = vim.v.servername or ""
  if socket ~= "" then
    ok("Neovim RPC socket: " .. socket)
  else
    warn("Neovim RPC socket not found (start Neovim with --listen or set NVIM_LISTEN_ADDRESS)")
  end

  -- Diff layout
  local cfg = require("claude-preview").config or {}
  local layout = (cfg.diff and cfg.diff.layout) or "unknown"
  ok("Diff layout: " .. layout)

  -- ── Claude Code backend ───────────────────────────────────────

  start("Claude Code backend")

  -- jq (required by Claude Code shell hooks)
  if vim.fn.executable("jq") == 1 then
    ok("jq is available")
  else
    warn("jq not found in PATH (required by Claude Code hook scripts)")
  end

  -- Hook scripts executable
  local src = debug.getinfo(1, "S").source
  local lua_file = src:sub(2)
  local lua_dir  = vim.fn.fnamemodify(lua_file, ":h")
  local bin      = vim.fn.fnamemodify(lua_dir, ":h:h") .. "/bin"

  for _, script in ipairs({
    "claude-preview-diff.sh",
    "claude-close-diff.sh",
    "nvim-socket.sh",
    "nvim-send.sh",
    "apply-edit.lua",
    "apply-multi-edit.lua",
  }) do
    local path = bin .. "/" .. script
    if vim.fn.filereadable(path) == 1 and vim.fn.executable(path) == 1 then
      ok(script .. " is executable")
    elseif vim.fn.filereadable(path) == 1 then
      warn(script .. " exists but is not executable (run: chmod +x " .. path .. ")")
    else
      error(script .. " not found at " .. path)
    end
  end

  -- .claude/settings.local.json
  local settings = vim.fn.getcwd() .. "/.claude/settings.local.json"
  local f = io.open(settings, "r")
  if not f then
    warn(".claude/settings.local.json not found — run :ClaudePreviewInstallHooks")
  else
    local raw = f:read("*a")
    f:close()
    local parsed_ok, data = pcall(vim.json.decode, raw)
    if not parsed_ok then
      error(".claude/settings.local.json is invalid JSON")
    elseif not (data.hooks and data.hooks.PreToolUse) then
      warn(".claude/settings.local.json exists but claude-preview hooks are not installed")
    else
      local found = false
      for _, entry in ipairs(data.hooks.PreToolUse) do
        if entry.hooks and entry.hooks[1] and
           tostring(entry.hooks[1].command or ""):find("claude-preview", 1, true) then
          found = true
          break
        end
      end
      if found then
        ok("Claude Code hooks are installed")
      else
        warn("claude-preview hooks not found — run :ClaudePreviewInstallHooks")
      end
    end
  end

  -- ── OpenCode backend ──────────────────────────────────────────

  start("OpenCode backend")

  -- OpenCode CLI
  if vim.fn.executable("opencode") == 1 then
    ok("opencode is available in PATH")
  else
    warn("opencode not found in PATH (install from https://opencode.ai)")
  end

  -- OpenCode plugin installed
  local opencode_plugin = vim.fn.getcwd() .. "/.opencode/plugins/index.ts"
  if vim.fn.filereadable(opencode_plugin) == 1 then
    ok("OpenCode plugin is installed (.opencode/plugins/)")
  else
    warn("OpenCode plugin not installed — run :CodePreviewInstallOpenCodeHooks")
  end
end

return M
