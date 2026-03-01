local M = {}

function M.check()
  -- vim.health API differs between Neovim 0.9 and 0.10+
  local h = vim.health or require("health")
  local ok    = h.ok    or h.report_ok
  local warn  = h.warn  or h.report_warn
  local error = h.error or h.report_error
  local start = h.start or h.report_start

  start("claude-preview.nvim")

  -- 1. jq
  if vim.fn.executable("jq") == 1 then
    ok("jq is available")
  else
    error("jq not found in PATH (required by hook scripts)")
  end

  -- 2. nvim (always true — we're inside nvim)
  ok("nvim is available")

  -- 3. Hook scripts executable
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

  -- 4. .claude/settings.local.json
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
        ok("claude-preview hooks are installed in .claude/settings.local.json")
      else
        warn("claude-preview hooks not found in .claude/settings.local.json — run :ClaudePreviewInstallHooks")
      end
    end
  end

  -- 5. Neovim RPC socket
  local socket = vim.v.servername or ""
  if socket ~= "" then
    ok("Neovim RPC socket: " .. socket)
  else
    warn("Neovim RPC socket not found (start Neovim with --listen or set NVIM_LISTEN_ADDRESS)")
  end
end

return M
