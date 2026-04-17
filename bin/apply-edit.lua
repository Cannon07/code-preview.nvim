#!/usr/bin/env -S nvim --headless -l
-- apply-edit.lua — Apply a single Edit (old_string → new_string) to a file.
--
-- Usage (via nvim --headless -l):
--   nvim --headless -l apply-edit.lua <file_path> <old_string> <new_string> <replace_all> <output_path>
--
-- replace_all: "true" or "false"

local file_path   = arg[1]
local old_string  = arg[2]
local new_string  = arg[3]
local replace_all = arg[4] == "true"
local output_path = arg[5]

-- Read the file (empty string if it does not exist yet)
local content = ""
local fh = io.open(file_path, "r")
if fh then
  content = fh:read("*a")
  fh:close()
end

-- Literal replacement (string.find plain=true prevents pattern interpretation)
if replace_all then
  -- Replace all occurrences
  local result = {}
  local search_start = 1
  if old_string == "" then
    -- Empty old_string: prepend new_string (handles "insert into empty file")
    result = { new_string, content }
  else
    while true do
      local s, e = string.find(content, old_string, search_start, true)
      if not s then
        table.insert(result, content:sub(search_start))
        break
      end
      table.insert(result, content:sub(search_start, s - 1))
      table.insert(result, new_string)
      search_start = e + 1
    end
  end
  content = table.concat(result)
else
  -- Replace first occurrence only
  if old_string == "" then
    -- Empty old_string: prepend new_string (handles "insert into empty file")
    content = new_string .. content
  else
    local s, e = string.find(content, old_string, 1, true)
    if s then
      content = content:sub(1, s - 1) .. new_string .. content:sub(e + 1)
    end
  end
end

-- Write the result
local out = assert(io.open(output_path, "w"))
out:write(content)
out:close()

os.exit(0)
