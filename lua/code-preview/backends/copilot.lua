local M = {}

-- Resolve plugin root from this file's location
local function plugin_root()
  local src = debug.getinfo(1, "S").source
  local lua_file = src:sub(2)
  local lua_dir = vim.fn.fnamemodify(lua_file, ":h")
  -- Go up three levels: backends/ → code-preview/ → lua/ → plugin root
  return vim.fn.fnamemodify(lua_dir, ":h:h:h")
end

local function scripts_dir() return plugin_root() .. "/backends/copilot" end
local function pre_script()  return scripts_dir() .. "/code-preview-diff.sh" end
local function post_script() return scripts_dir() .. "/code-close-diff.sh"  end

local function hooks_dir()   return vim.fn.getcwd() .. "/.github/hooks" end
local function config_path() return hooks_dir() .. "/code-preview.json" end

-- Shell-quote a path for use inside the `bash` field of hooks.json.
local function shquote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- True iff `path` looks like a code-preview.json our installer produced. We
-- match on the pre-tool adapter script name — every install() invocation
-- writes it verbatim, and it's specific enough that user-authored hook
-- files are unlikely to collide. Guards status display and uninstall from
-- misidentifying a user-owned file with the same name.
function M.is_our_config(path)
  if vim.fn.filereadable(path) == 0 then return false end
  local f = io.open(path, "r")
  if not f then return false end
  local content = f:read("*a")
  f:close()
  return content and content:find("code-preview-diff.sh", 1, true) ~= nil
end

local function ensure_executable(path)
  if vim.fn.filereadable(path) == 0 then
    vim.notify("[code-preview] script not found: " .. path, vim.log.levels.ERROR)
    return false
  end
  vim.fn.system({ "chmod", "+x", path })
  return true
end

function M.install()
  local pre, post = pre_script(), post_script()
  if not (ensure_executable(pre) and ensure_executable(post)) then return end

  vim.fn.mkdir(hooks_dir(), "p")

  local data = {
    version = 1,
    hooks = {
      preToolUse  = { { type = "command", bash = shquote(pre),  timeoutSec = 30 } },
      postToolUse = { { type = "command", bash = shquote(post), timeoutSec = 30 } },
    },
  }

  local path = config_path()
  local f = assert(io.open(path, "w"), "Cannot write to " .. path)
  f:write(vim.json.encode(data))
  f:close()

  vim.notify("[code-preview] Copilot CLI hooks installed → " .. path, vim.log.levels.INFO)
end

function M.uninstall()
  local path = config_path()
  if vim.fn.filereadable(path) == 0 then
    vim.notify("[code-preview] No Copilot hooks found at " .. path, vim.log.levels.WARN)
    return
  end
  if not M.is_our_config(path) then
    vim.notify(
      "[code-preview] Refusing to remove " .. path .. ": not produced by code-preview install. Delete it manually if intentional.",
      vim.log.levels.WARN
    )
    return
  end
  vim.fn.delete(path)
  -- Try to prune the hooks dir if it became empty (don't touch parents).
  pcall(vim.fn.delete, hooks_dir(), "d")
  vim.notify("[code-preview] Copilot CLI hooks uninstalled", vim.log.levels.INFO)
end

return M
