local M = {}

-- Resolve plugin root from this file's location
local function plugin_root()
  local src = debug.getinfo(1, "S").source
  -- src is "@/absolute/path/to/lua/code-preview/backends/opencode.lua"
  local lua_file = src:sub(2)
  local lua_dir  = vim.fn.fnamemodify(lua_file, ":h")    -- .../lua/code-preview/backends
  -- Go up three levels: backends/ → code-preview/ → lua/ → plugin root
  return vim.fn.fnamemodify(lua_dir, ":h:h:h")
end

local function bin_dir()
  return plugin_root() .. "/bin"
end

local function plugin_source_dir()
  return plugin_root() .. "/backends/opencode"
end

local function opencode_target_dir()
  return vim.fn.getcwd() .. "/.opencode/plugins"
end

function M.install()
  local source = plugin_source_dir()
  local index_src = source .. "/index.ts"

  if vim.fn.filereadable(index_src) == 0 then
    vim.notify("[code-preview] OpenCode plugin source not found: " .. index_src, vim.log.levels.ERROR)
    return
  end

  local target = opencode_target_dir()
  vim.fn.mkdir(target, "p")

  -- Copy plugin files
  local files = { "index.ts", "package.json", "tsconfig.json" }
  for _, file in ipairs(files) do
    local src_path = source .. "/" .. file
    local dst_path = target .. "/" .. file
    if vim.fn.filereadable(src_path) == 1 then
      vim.fn.system({ "cp", src_path, dst_path })
    end
  end

  -- Write bin-path.txt so the plugin can find the core scripts
  local bin_path_file = target .. "/bin-path.txt"
  local bf = io.open(bin_path_file, "w")
  if bf then
    bf:write(bin_dir())
    bf:close()
  end

  vim.notify("[code-preview] OpenCode plugin installed → " .. target, vim.log.levels.INFO)
end

function M.uninstall()
  local target = opencode_target_dir()

  local files = { "index.ts", "package.json", "tsconfig.json", "bin-path.txt" }
  local removed = false
  for _, file in ipairs(files) do
    local path = target .. "/" .. file
    if vim.fn.filereadable(path) == 1 then
      vim.fn.delete(path)
      removed = true
    end
  end

  -- Also clean up legacy files from previous versions
  for _, legacy in ipairs({ "nvim.ts", "edits.ts" }) do
    local path = target .. "/" .. legacy
    if vim.fn.filereadable(path) == 1 then
      vim.fn.delete(path)
    end
  end

  if removed then
    -- Remove plugins/ directory only if empty (don't touch other .opencode files)
    vim.fn.delete(target, "d")
    vim.notify("[code-preview] OpenCode plugin removed", vim.log.levels.INFO)
  else
    vim.notify("[code-preview] No OpenCode plugin found in " .. target, vim.log.levels.WARN)
  end
end

return M
