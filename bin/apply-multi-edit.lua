#!/usr/bin/env -S nvim --headless -l
-- apply-multi-edit.lua — Apply a MultiEdit (multiple edits) to a file.
--
-- Usage (via nvim --headless -l):
--   nvim --headless -l apply-multi-edit.lua <hook_json_string> <output_path>
--
-- arg[1]: full hook JSON (the same JSON that arrives on stdin for the hook)
-- arg[2]: path to write the resulting file content

local hook_json  = arg[1]
local output_path = arg[2]

-- Parse JSON via vim.json (always available in Neovim)
local ok, input = pcall(vim.json.decode, hook_json)
if not ok then
  io.stderr:write("apply-multi-edit.lua: failed to parse JSON: " .. tostring(input) .. "\n")
  os.exit(1)
end

local file_path = input.tool_input.file_path
local edits     = input.tool_input.edits or {}

-- Read the file (empty string if it does not exist yet)
local content = ""
local fh = io.open(file_path, "r")
if fh then
  content = fh:read("*a")
  fh:close()
end

-- Apply each edit sequentially (literal, not pattern-based)
for _, edit in ipairs(edits) do
  local old = edit.old_string or ""
  local new = edit.new_string or ""
  if old == "" then
    -- Empty old_string → prepend new content (matches Python behaviour)
    content = new .. content
  else
    local s, e = string.find(content, old, 1, true)
    if s then
      content = content:sub(1, s - 1) .. new .. content:sub(e + 1)
    end
    -- If not found, skip silently (matches Python behaviour)
  end
end

-- Write the result
local out = assert(io.open(output_path, "w"))
out:write(content)
out:close()

os.exit(0)
