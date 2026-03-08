local M = {}

-- { [absolute_path] = "modified" | "created" | "deleted" }
-- Pure Lua key-value store, no external dependencies
local pending = {}

-- Normalize path: make absolute and strip trailing slash
local function normalize(filepath)
  local p = vim.fn.fnamemodify(filepath, ":p")
  return (p:gsub("/$", ""))
end

function M.set(filepath, status)
  pending[normalize(filepath)] = status
end

function M.clear(filepath)
  pending[normalize(filepath)] = nil
end

function M.clear_all()
  pending = {}
end

function M.get(filepath)
  return pending[normalize(filepath)]
end

function M.get_all()
  return vim.deepcopy(pending)
end

function M.clear_by_status(status)
  for path, s in pairs(pending) do
    if s == status then
      pending[path] = nil
    end
  end
end

return M
