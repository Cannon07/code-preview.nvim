local M = {}

-- Resolve the absolute path to the plugin's bin/ directory.
-- We use debug.getinfo so this works regardless of where the plugin is installed.
local function bin_dir()
  local src = debug.getinfo(1, "S").source
  -- src is "@/absolute/path/to/lua/claude-preview/hooks.lua"
  local lua_file = src:sub(2)                            -- strip leading "@"
  local lua_dir  = vim.fn.fnamemodify(lua_file, ":h")    -- .../lua/claude-preview
  -- Go up two levels: claude-preview/ → lua/ → plugin root, then into bin/
  return vim.fn.fnamemodify(lua_dir, ":h:h") .. "/bin"
end

local HOOK_MARKER = "claude-preview"   -- used to identify our entries

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

function M.install()
  local dir = bin_dir()
  local preview = dir .. "/claude-preview-diff.sh"
  local close   = dir .. "/claude-close-diff.sh"

  -- Verify scripts exist
  if vim.fn.filereadable(preview) == 0 then
    vim.notify("[claude-preview] hook script not found: " .. preview, vim.log.levels.ERROR)
    return
  end

  local path = settings_path()
  local data = read_settings(path)

  -- Initialise missing structure
  data.hooks = data.hooks or {}
  data.hooks.PreToolUse  = data.hooks.PreToolUse  or {}
  data.hooks.PostToolUse = data.hooks.PostToolUse or {}

  -- Remove any existing claude-preview entries to avoid duplicates
  local function remove_ours(list)
    local filtered = {}
    for _, entry in ipairs(list) do
      if not (entry.hooks and entry.hooks[1] and
              tostring(entry.hooks[1].command or ""):find(HOOK_MARKER, 1, true)) then
        table.insert(filtered, entry)
      end
    end
    return filtered
  end

  data.hooks.PreToolUse  = remove_ours(data.hooks.PreToolUse)
  data.hooks.PostToolUse = remove_ours(data.hooks.PostToolUse)

  -- Add our entries
  table.insert(data.hooks.PreToolUse, {
    matcher = "Edit|Write|MultiEdit",
    hooks   = { { type = "command", command = preview } },
  })
  table.insert(data.hooks.PostToolUse, {
    matcher = "Edit|Write|MultiEdit",
    hooks   = { { type = "command", command = close } },
  })

  write_settings(path, data)
  vim.notify("[claude-preview] Hooks installed → " .. path, vim.log.levels.INFO)
end

function M.uninstall()
  local path = settings_path()
  local data = read_settings(path)

  if not data.hooks then
    vim.notify("[claude-preview] No hooks found in " .. path, vim.log.levels.WARN)
    return
  end

  local function remove_ours(list)
    local filtered = {}
    for _, entry in ipairs(list or {}) do
      if not (entry.hooks and entry.hooks[1] and
              tostring(entry.hooks[1].command or ""):find(HOOK_MARKER, 1, true)) then
        table.insert(filtered, entry)
      end
    end
    return filtered
  end

  data.hooks.PreToolUse  = remove_ours(data.hooks.PreToolUse)
  data.hooks.PostToolUse = remove_ours(data.hooks.PostToolUse)

  write_settings(path, data)
  vim.notify("[claude-preview] Hooks removed from " .. path, vim.log.levels.INFO)
end

return M
