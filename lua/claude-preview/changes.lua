local M = {}

-- { [absolute_path] = "modified" | "created" }
-- Pure Lua key-value store, no external dependencies
local pending = {}

function M.set(filepath, status)
  pending[vim.fn.fnamemodify(filepath, ":p")] = status
end

function M.clear(filepath)
  pending[vim.fn.fnamemodify(filepath, ":p")] = nil
end

function M.clear_all()
  pending = {}
end

function M.get(filepath)
  return pending[vim.fn.fnamemodify(filepath, ":p")]
end

function M.get_all()
  return vim.deepcopy(pending)
end

return M
