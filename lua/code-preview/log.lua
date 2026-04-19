--- code-preview.nvim — Logging module
---
--- Opt-in debug logging following Neovim plugin conventions.
--- - WARN/ERROR: shown to user via vim.notify()
--- - DEBUG/INFO: written to log file only (when enabled)
--- - Log file: vim.fn.stdpath("log") .. "/code-preview.log"

local M = {}

local log_file_path = nil
local enabled = false

--- Initialise logging. Called once from setup().
--- @param opts { debug: boolean }
function M.init(opts)
  enabled = opts and opts.debug or false
  if enabled then
    log_file_path = vim.fn.stdpath("log") .. "/code-preview.log"
  end
end

--- Write a line to the log file. No-op when debug is disabled.
--- @param level string "DEBUG"|"INFO"|"WARN"|"ERROR"
--- @param msg string
local function write(level, msg)
  if not enabled or not log_file_path then
    return
  end
  local f = io.open(log_file_path, "a")
  if not f then
    return
  end
  f:write(string.format("[%s] [%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), level, msg))
  f:close()
end

function M.debug(msg) write("DEBUG", msg) end
function M.info(msg) write("INFO", msg) end

function M.warn(msg)
  write("WARN", msg)
  vim.notify("[code-preview] " .. msg, vim.log.levels.WARN)
end

function M.error(msg)
  write("ERROR", msg)
  vim.notify("[code-preview] " .. msg, vim.log.levels.ERROR)
end

--- Format helper for structured messages.
--- @param template string format string
--- @param ... any format arguments
--- @return string
function M.fmt(template, ...)
  return string.format(template, ...)
end

--- Check whether debug logging is enabled.
--- @return boolean
function M.is_enabled()
  return enabled
end

--- Return the log file path (for shell scripts via hook_context).
--- @return string|nil
function M.get_log_path()
  return log_file_path
end

return M
