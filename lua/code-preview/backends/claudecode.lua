local M = {}

-- Resolve the absolute path to the plugin's bin/ directory.
-- We use debug.getinfo so this works regardless of where the plugin is installed.
-- Resolve plugin root from this file's location
local function plugin_root()
  local src = debug.getinfo(1, "S").source
  -- src is "@/absolute/path/to/lua/code-preview/backends/claudecode.lua"
  local lua_file = src:sub(2)                            -- strip leading "@"
  local lua_dir  = vim.fn.fnamemodify(lua_file, ":h")    -- .../lua/code-preview/backends
  -- Go up three levels: backends/ → code-preview/ → lua/ → plugin root
  return vim.fn.fnamemodify(lua_dir, ":h:h:h")
end

-- Path to shared utilities (bin/)
local function bin_dir()
  return plugin_root() .. "/bin"
end

-- Path to Claude Code adapter scripts (backends/claudecode/)
local function scripts_dir()
  return plugin_root() .. "/backends/claudecode"
end

local HOOK_MARKER = "code-preview"
local LEGACY_HOOK_MARKER = "claude-preview"  -- match old entries during transition

local function settings_path()
  return vim.fn.getcwd() .. "/.claude/settings.local.json"
end

local function read_settings(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  if raw == "" then return {} end
  local ok, data = pcall(vim.json.decode, raw)
  return ok and data or {}
end

local function write_settings(path, data)
  -- Ensure parent directory exists
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"), "Cannot write to " .. path)
  f:write(vim.json.encode(data))
  f:close()
end

-- Remove entries matching either the current or legacy hook marker.
-- This lets users who installed with the old name uninstall after upgrading.
local function remove_ours(list)
  local filtered = {}
  for _, entry in ipairs(list) do
    local cmd = ""
    if entry.hooks and entry.hooks[1] then
      cmd = tostring(entry.hooks[1].command or "")
    end
    if not (cmd:find(HOOK_MARKER, 1, true) or cmd:find(LEGACY_HOOK_MARKER, 1, true)) then
      table.insert(filtered, entry)
    end
  end
  return filtered
end

function M.install()
  local dir = scripts_dir()
  local preview = dir .. "/code-preview-diff.sh"
  local close   = dir .. "/code-close-diff.sh"

  -- Verify scripts exist
  if vim.fn.filereadable(preview) == 0 then
    vim.notify("[code-preview] hook script not found: " .. preview, vim.log.levels.ERROR)
    return
  end

  local path = settings_path()
  local data = read_settings(path)

  -- Initialise missing structure
  data.hooks = data.hooks or {}
  data.hooks.PreToolUse  = data.hooks.PreToolUse  or {}
  data.hooks.PostToolUse = data.hooks.PostToolUse or {}

  data.hooks.PreToolUse  = remove_ours(data.hooks.PreToolUse)
  data.hooks.PostToolUse = remove_ours(data.hooks.PostToolUse)

  -- Add our entries
  table.insert(data.hooks.PreToolUse, {
    matcher = "Edit|Write|MultiEdit|Bash",
    hooks   = { { type = "command", command = preview } },
  })
  table.insert(data.hooks.PostToolUse, {
    matcher = "Edit|Write|MultiEdit|Bash",
    hooks   = { { type = "command", command = close } },
  })

  write_settings(path, data)
  vim.notify("[code-preview] Hooks installed → " .. path, vim.log.levels.INFO)
end

function M.uninstall()
  local path = settings_path()
  local data = read_settings(path)

  if not data.hooks then
    vim.notify("[code-preview] No hooks found in " .. path, vim.log.levels.WARN)
    return
  end

  data.hooks.PreToolUse  = remove_ours(data.hooks.PreToolUse or {})
  data.hooks.PostToolUse = remove_ours(data.hooks.PostToolUse or {})

  write_settings(path, data)
  vim.notify("[code-preview] Hooks removed from " .. path, vim.log.levels.INFO)
end

return M
