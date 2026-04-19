#!/usr/bin/env -S nvim --headless -l
--- apply-patch.lua — Parse custom patch format and produce per-file original/proposed pairs
---
--- Usage: nvim --headless -l apply-patch.lua <patch_json> <cwd> <output_dir>
---
--- Reads the patch text from a JSON file ({"patch_text": "..."}), parses the
--- custom patch format used by OpenCode/GPT models:
---
---   *** Begin Patch
---   *** Update File: path/to/file
---   @@
---   -old line
---   +new line
---    context line
---   *** End Patch
---
--- Writes per-file results to output_dir:
---   <output_dir>/files.json        — list of {path, orig, prop} objects
---   <output_dir>/<hash>-orig       — original content
---   <output_dir>/<hash>-prop       — proposed content

local patch_json_path = arg[1]
local cwd = arg[2]
local output_dir = arg[3]

if not patch_json_path or not cwd or not output_dir then
  io.stderr:write("Usage: nvim --headless -l apply-patch.lua <patch_json> <cwd> <output_dir>\n")
  vim.cmd("cquit! 1")
  return
end

-- Read patch text from JSON file
local f = io.open(patch_json_path, "r")
if not f then
  io.stderr:write("Cannot open patch JSON: " .. patch_json_path .. "\n")
  vim.cmd("cquit! 1")
  return
end
local json_str = f:read("*a")
f:close()

local ok, data = pcall(vim.json.decode, json_str)
if not ok or not data.patch_text then
  io.stderr:write("Invalid patch JSON or missing patch_text\n")
  vim.cmd("cquit! 1")
  return
end

local patch_text = data.patch_text

-- Parse the custom patch format into file sections
local files = {}
local current_file = nil
local current_action = nil -- "update", "add", "delete"

for line in (patch_text .. "\n"):gmatch("([^\n]*)\n") do
  local update_path = line:match("^%*%*%* Update File:%s*(.+)$")
  local add_path = line:match("^%*%*%* Add File:%s*(.+)$")
  local delete_path = line:match("^%*%*%* Delete File:%s*(.+)$")

  if update_path then
    current_file = { path = update_path:gsub("%s+$", ""), action = "update", hunks = {}, current_hunk = nil }
    table.insert(files, current_file)
    current_action = "update"
  elseif add_path then
    current_file = { path = add_path:gsub("%s+$", ""), action = "add", hunks = {}, current_hunk = nil }
    table.insert(files, current_file)
    current_action = "add"
  elseif delete_path then
    current_file = { path = delete_path:gsub("%s+$", ""), action = "delete", hunks = {}, current_hunk = nil }
    table.insert(files, current_file)
    current_action = "delete"
  elseif line:match("^@@") and current_file then
    -- Start a new hunk
    current_file.current_hunk = { lines = {} }
    table.insert(current_file.hunks, current_file.current_hunk)
  elseif line == "*** End Patch" or line == "*** Begin Patch" then
    current_file = nil
  elseif current_file and current_file.current_hunk then
    table.insert(current_file.current_hunk.lines, line)
  end
end

-- Resolve file path relative to cwd
local function resolve_path(path)
  if path:sub(1, 1) == "/" then
    return path
  end
  return cwd .. "/" .. path
end

-- Read file content as lines
local function read_lines(path)
  local fh = io.open(path, "r")
  if not fh then
    return {}
  end
  local lines = {}
  for line in fh:lines() do
    table.insert(lines, line)
  end
  fh:close()
  return lines
end

-- Apply hunks to original lines to produce proposed lines
local function apply_hunks(orig_lines, hunks)
  if #hunks == 0 then
    return orig_lines
  end

  local result = {}
  local orig_idx = 1

  for _, hunk in ipairs(hunks) do
    -- Each hunk has context lines (space-prefixed), removals (-), additions (+)
    -- Context lines help us find position in the original file

    -- First, find where this hunk starts in the original by matching context
    local hunk_lines = hunk.lines

    -- Collect the context/remove pattern to locate position
    local match_lines = {}
    for _, hl in ipairs(hunk_lines) do
      local prefix = hl:sub(1, 1)
      if prefix == " " then
        table.insert(match_lines, { type = "context", text = hl:sub(2) })
      elseif prefix == "-" then
        table.insert(match_lines, { type = "remove", text = hl:sub(2) })
      elseif prefix == "+" then
        table.insert(match_lines, { type = "add", text = hl:sub(2) })
      else
        -- Lines without a recognized prefix are treated as context
        table.insert(match_lines, { type = "context", text = hl })
      end
    end

    -- Find the start position by matching context/remove lines against original
    local first_match_text = nil
    for _, ml in ipairs(match_lines) do
      if ml.type == "context" or ml.type == "remove" then
        first_match_text = ml.text
        break
      end
    end

    if first_match_text then
      -- Advance orig_idx to find the matching line
      while orig_idx <= #orig_lines do
        if orig_lines[orig_idx] == first_match_text then
          break
        end
        -- Copy non-matching lines to result (they're before this hunk)
        table.insert(result, orig_lines[orig_idx])
        orig_idx = orig_idx + 1
      end
    end

    -- Apply the hunk
    for _, ml in ipairs(match_lines) do
      if ml.type == "context" then
        table.insert(result, ml.text)
        orig_idx = orig_idx + 1
      elseif ml.type == "remove" then
        -- Skip original line (don't add to result)
        orig_idx = orig_idx + 1
      elseif ml.type == "add" then
        table.insert(result, ml.text)
        -- Don't advance orig_idx
      end
    end
  end

  -- Copy remaining original lines
  while orig_idx <= #orig_lines do
    table.insert(result, orig_lines[orig_idx])
    orig_idx = orig_idx + 1
  end

  return result
end

-- Write lines to a file
local function write_lines(path, lines)
  local fh = io.open(path, "w")
  if not fh then
    return false
  end
  for i, line in ipairs(lines) do
    fh:write(line)
    if i < #lines then
      fh:write("\n")
    end
  end
  -- Add trailing newline
  if #lines > 0 then
    fh:write("\n")
  end
  fh:close()
  return true
end

-- Process each file section
local results = {}
for i, file_section in ipairs(files) do
  local abs_path = resolve_path(file_section.path)
  local tag = string.format("%02d", i)
  local orig_out = output_dir .. "/" .. tag .. "-orig"
  local prop_out = output_dir .. "/" .. tag .. "-prop"

  if file_section.action == "delete" then
    local orig_lines = read_lines(abs_path)
    write_lines(orig_out, orig_lines)
    write_lines(prop_out, {})
  elseif file_section.action == "add" then
    write_lines(orig_out, {})
    -- For add, all hunk lines should be additions
    local new_lines = {}
    for _, hunk in ipairs(file_section.hunks) do
      for _, hl in ipairs(hunk.lines) do
        if hl:sub(1, 1) == "+" then
          table.insert(new_lines, hl:sub(2))
        elseif hl:sub(1, 1) ~= "-" then
          -- Bare lines (no prefix) in add mode are content
          table.insert(new_lines, hl)
        end
      end
    end
    write_lines(prop_out, new_lines)
  else -- update
    local orig_lines = read_lines(abs_path)
    write_lines(orig_out, orig_lines)
    local proposed = apply_hunks(orig_lines, file_section.hunks)
    write_lines(prop_out, proposed)
  end

  table.insert(results, {
    path = abs_path,
    rel_path = file_section.path,
    action = file_section.action,
    orig = orig_out,
    prop = prop_out,
  })
end

-- Write the file list as JSON
local results_path = output_dir .. "/files.json"
local rf = io.open(results_path, "w")
if rf then
  rf:write(vim.json.encode(results))
  rf:close()
end

vim.cmd("qall!")
