local M = {}

-- Track the diff tab so we can close it later
local diff_tab = nil
local diff_bufs = {}
local diff_augroup = nil
local diff_file_path = nil  -- tag: which file this diff belongs to

-- Queue for pending diffs (OpenCode fires all before-hooks before any after-hooks,
-- so we queue subsequent diffs and show them as each one is closed).
local diff_queue = {}

-- Namespaces created at module load, but colors applied inside show_diff()
-- after setup() has merged the user config.
local current_ns  = vim.api.nvim_create_namespace("claude_diff_current_hl")
local proposed_ns = vim.api.nvim_create_namespace("claude_diff_proposed_hl")
local inline_ns   = vim.api.nvim_create_namespace("claude_diff_inline_hl")

local function apply_highlights(config)
  local cur = config.highlights.current
  local pro = config.highlights.proposed
  for name, hl in pairs(cur) do
    vim.api.nvim_set_hl(current_ns, name, hl)
  end
  for name, hl in pairs(pro) do
    vim.api.nvim_set_hl(proposed_ns, name, hl)
  end
end

local function read_file_lines(path)
  local lines = {}
  local f = io.open(path, "r")
  if f then
    for line in f:lines() do
      table.insert(lines, line)
    end
    f:close()
  end
  return lines
end

function M.is_open(file_path)
  if diff_tab == nil or not vim.api.nvim_tabpage_is_valid(diff_tab) then
    return false
  end
  -- If a file_path is given, only return true if the diff is for that file
  if file_path and file_path ~= "" and diff_file_path and diff_file_path ~= file_path then
    return false
  end
  return true
end

-- Module-level storage for inline diff line numbers
local inline_line_numbers = {}

-- Module-level storage for inline diff line types
local inline_line_types = {}

-- Track which window is the inline diff window
local inline_diff_win = nil

-- Statuscolumn function for inline diff: shows old|new line numbers + sign
function M.inline_statuscolumn(col_width)
  -- Only apply to the inline diff window
  if vim.g.statusline_winid ~= inline_diff_win then
    return ""
  end
  local lnum = vim.v.lnum
  if not inline_line_numbers[lnum] then
    return string.rep(" ", col_width * 2 + 3)
  end
  local old_num = inline_line_numbers[lnum][1]
  local new_num = inline_line_numbers[lnum][2]
  local old_str = old_num and string.format("%" .. col_width .. "d", old_num) or string.rep(" ", col_width)
  local new_str = new_num and string.format("%" .. col_width .. "d", new_num) or string.rep(" ", col_width)

  local line_type = inline_line_types[lnum]
  local sign = " "
  if line_type == "added" then
    sign = "%#ClaudeDiffInlineAddedSign#+%*"
  elseif line_type == "removed" then
    sign = "%#ClaudeDiffInlineRemovedSign#-%*"
  end

  return old_str .. "│" .. new_str .. " " .. sign
end

local function apply_inline_highlights(config)
  local hl = config.highlights.inline or {}
  vim.api.nvim_set_hl(0, "ClaudeDiffInlineAdded", hl.added or { bg = "#2e4c2e" })
  vim.api.nvim_set_hl(0, "ClaudeDiffInlineRemoved", hl.removed or { bg = "#4c2e2e" })
  vim.api.nvim_set_hl(0, "ClaudeDiffInlineAddedText", hl.added_text or { bg = "#3a6e3a" })
  vim.api.nvim_set_hl(0, "ClaudeDiffInlineRemovedText", hl.removed_text or { bg = "#6e3a3a" })
  vim.api.nvim_set_hl(0, "ClaudeDiffInlineAddedSign", { fg = "#73e896", bold = true })
  vim.api.nvim_set_hl(0, "ClaudeDiffInlineRemovedSign", { fg = "#f47070", bold = true })
end

-- Compute character-level diff between two lines, returns list of {start, end} changed ranges
local function char_diff_ranges(old_line, new_line)
  -- Find common prefix
  local prefix = 0
  local min_len = math.min(#old_line, #new_line)
  while prefix < min_len and old_line:byte(prefix + 1) == new_line:byte(prefix + 1) do
    prefix = prefix + 1
  end
  -- Find common suffix
  local suffix = 0
  while suffix < (min_len - prefix)
    and old_line:byte(#old_line - suffix) == new_line:byte(#new_line - suffix) do
    suffix = suffix + 1
  end
  -- The changed range in old_line: prefix+1 to #old_line-suffix
  -- The changed range in new_line: prefix+1 to #new_line-suffix
  return prefix, #old_line - suffix, #new_line - suffix
end

local function build_inline_diff(original_path, proposed_path)
  local orig_lines = read_file_lines(original_path)
  local prop_lines = read_file_lines(proposed_path)
  local orig_text = #orig_lines > 0 and (table.concat(orig_lines, "\n") .. "\n") or ""
  local prop_text = #prop_lines > 0 and (table.concat(prop_lines, "\n") .. "\n") or ""

  local diff_str = vim.diff(orig_text, prop_text, {
    result_type = "unified",
    ctxlen = 999999,
  })

  if not diff_str or diff_str == "" then
    return prop_lines, {}, {}, {}, {}
  end

  local display_lines = {}
  local line_highlights = {}    -- { {line_idx, hl_group} }
  local char_highlights = {}    -- { {line_idx, hl_group, col_start, col_end} }
  local line_numbers = {}       -- { {old_num|nil, new_num|nil} } per display line
  local line_types = {}         -- { [lnum] = "added"|"removed"|nil } per display line

  -- First pass: collect all lines with their types
  local entries = {}
  for line in diff_str:gmatch("([^\n]*)\n?") do
    if line:sub(1, 3) == "---" or line:sub(1, 3) == "+++" then
      -- skip
    elseif line:sub(1, 2) == "@@" then
      -- skip hunk headers — not useful when showing the full file
    elseif line:sub(1, 1) == "-" then
      table.insert(entries, { type = "removed", text = line:sub(2) })
    elseif line:sub(1, 1) == "+" then
      table.insert(entries, { type = "added", text = line:sub(2) })
    elseif line ~= "" or #entries > 0 then
      -- Context lines have a leading space in unified diff
      local content = line:sub(1, 1) == " " and line:sub(2) or line
      table.insert(entries, { type = "context", text = content })
    end
  end

  -- Second pass: detect removed/added pairs for char-level highlighting
  local old_num = 0
  local new_num = 0
  local i = 1
  while i <= #entries do
    local e = entries[i]
    if e.type == "removed" then
      -- Collect consecutive removed lines
      local removed_start = i
      while i <= #entries and entries[i].type == "removed" do
        i = i + 1
      end
      local removed_end = i - 1
      -- Collect consecutive added lines
      local added_start = i
      while i <= #entries and entries[i].type == "added" do
        i = i + 1
      end
      local added_end = i - 1

      -- Add removed lines
      for j = removed_start, removed_end do
        table.insert(display_lines, entries[j].text)
        local line_idx = #display_lines - 1
        old_num = old_num + 1
        table.insert(line_numbers, { old_num, nil })
        table.insert(line_highlights, { line_idx, "ClaudeDiffInlineRemoved" })
        line_types[line_idx + 1] = "removed"
        -- If there's a matching added line, compute char diff
        local pair_idx = added_start + (j - removed_start)
        if pair_idx <= added_end then
          local old_content = entries[j].text
          local new_content = entries[pair_idx].text
          local prefix, old_end, _ = char_diff_ranges(old_content, new_content)
          if old_end > prefix then
            table.insert(char_highlights, { line_idx, "ClaudeDiffInlineRemovedText", prefix, old_end })
          end
        end
      end
      -- Add added lines
      for j = added_start, added_end do
        table.insert(display_lines, entries[j].text)
        local line_idx = #display_lines - 1
        new_num = new_num + 1
        table.insert(line_numbers, { nil, new_num })
        table.insert(line_highlights, { line_idx, "ClaudeDiffInlineAdded" })
        line_types[line_idx + 1] = "added"
        -- If there's a matching removed line, compute char diff
        local pair_idx = removed_start + (j - added_start)
        if pair_idx <= removed_end then
          local old_content = entries[pair_idx].text
          local new_content = entries[j].text
          local prefix, _, new_end = char_diff_ranges(old_content, new_content)
          if new_end > prefix then
            table.insert(char_highlights, { line_idx, "ClaudeDiffInlineAddedText", prefix, new_end })
          end
        end
      end
    else
      table.insert(display_lines, e.text)
      local line_idx = #display_lines - 1
      if e.type == "context" then
        old_num = old_num + 1
        new_num = new_num + 1
        table.insert(line_numbers, { old_num, new_num })
      elseif e.type == "added" then
        new_num = new_num + 1
        table.insert(line_numbers, { nil, new_num })
        table.insert(line_highlights, { line_idx, "ClaudeDiffInlineAdded" })
        line_types[line_idx + 1] = "added"
      elseif e.type == "removed" then
        old_num = old_num + 1
        table.insert(line_numbers, { old_num, nil })
        table.insert(line_highlights, { line_idx, "ClaudeDiffInlineRemoved" })
        line_types[line_idx + 1] = "removed"
      end
      i = i + 1
    end
  end

  return display_lines, line_highlights, char_highlights, line_numbers, line_types
end

local function show_inline_diff(original_path, proposed_path, real_file_path, cfg)
  apply_inline_highlights(cfg)

  local display_name = real_file_path or "unknown"
  local ft = vim.filetype.match({ filename = real_file_path }) or ""
  local display_lines, line_highlights, char_highlights, line_numbers, line_types =
    build_inline_diff(original_path, proposed_path)

  vim.cmd("tabnew")
  diff_tab = vim.api.nvim_get_current_tabpage()

  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)

  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].modifiable = false
  if ft ~= "" then vim.bo[buf].filetype = ft end

  -- Apply full-line highlights
  for _, hl in ipairs(line_highlights) do
    local line_len = #(display_lines[hl[1] + 1] or "")
    vim.api.nvim_buf_set_extmark(buf, inline_ns, hl[1], 0, {
      end_col = line_len,
      hl_group = hl[2],
      hl_eol = true,
      priority = 150,
    })
  end
  -- Apply character-level highlights on top
  for _, hl in ipairs(char_highlights) do
    vim.api.nvim_buf_set_extmark(buf, inline_ns, hl[1], hl[3], {
      end_col = hl[4],
      hl_group = hl[2],
      priority = 200,
    })
  end
  local win = vim.api.nvim_get_current_win()
  -- Store line numbers, types, and buffer for statuscolumn to access
  inline_line_numbers = line_numbers
  inline_line_types = line_types
  inline_diff_win = win

  -- Determine column width based on max line number
  local max_num = 0
  for _, nums in ipairs(line_numbers) do
    if nums[1] and nums[1] > max_num then max_num = nums[1] end
    if nums[2] and nums[2] > max_num then max_num = nums[2] end
  end
  local col_width = #tostring(max_num)

  vim.wo[win].winbar = "%#DiagnosticInfo# INLINE DIFF %* " .. display_name
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = "%!v:lua.require('code-preview.diff').inline_statuscolumn(" .. col_width .. ")"

  diff_bufs = { buf }

  -- Find first changed line for navigation
  local first_change_line = nil
  for lnum, _ in pairs(line_types) do
    if not first_change_line or lnum < first_change_line then
      first_change_line = lnum
    end
  end

  vim.keymap.set("n", "]c", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    for lnum = cur + 1, vim.api.nvim_buf_line_count(buf) do
      if line_types[lnum] then
        vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        return
      end
    end
  end, { buffer = buf, desc = "Next change" })

  vim.keymap.set("n", "[c", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    for lnum = cur - 1, 1, -1 do
      if line_types[lnum] then
        vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        return
      end
    end
  end, { buffer = buf, desc = "Previous change" })

  -- Jump to first change
  if first_change_line then
    vim.api.nvim_win_set_cursor(win, { first_change_line, 0 })
  end
end

function M.show_diff(original_path, proposed_path, real_file_path, abs_file_path)
  -- If a diff is already open for a DIFFERENT file, queue this one instead
  -- of replacing it. OpenCode fires all before-hooks before any after-hooks,
  -- so without queuing the user would only see the last file's diff.
  if M.is_open() and abs_file_path and diff_file_path ~= abs_file_path then
    -- Snapshot the temp file contents now — they'll be overwritten by the
    -- next hook call. We read them into memory so the queued diff survives.
    local orig_lines = {}
    local prop_lines = {}
    local f = io.open(original_path, "r")
    if f then for l in f:lines() do orig_lines[#orig_lines + 1] = l end; f:close() end
    f = io.open(proposed_path, "r")
    if f then for l in f:lines() do prop_lines[#prop_lines + 1] = l end; f:close() end
    table.insert(diff_queue, {
      orig_lines = orig_lines,
      prop_lines = prop_lines,
      real_file_path = real_file_path,
      abs_file_path = abs_file_path,
    })
    return
  end

  -- Close any existing diff first
  M.close_diff()

  -- Tag this diff with the absolute file path it belongs to.
  -- abs_file_path is the full path used by post-tool to check is_open();
  -- real_file_path is the display name shown in the winbar.
  diff_file_path = abs_file_path or real_file_path

  local cfg = require("code-preview").config

  -- Inline layout: single-buffer unified diff
  if cfg.diff.layout == "inline" then
    show_inline_diff(original_path, proposed_path, real_file_path, cfg)
    return
  end

  apply_highlights(cfg)

  local display_name = real_file_path or "unknown"
  local labels = cfg.diff.labels or { current = "CURRENT", proposed = "PROPOSED" }

  -- Detect filetype from the real file path for syntax highlighting
  local ft = vim.filetype.match({ filename = real_file_path }) or ""

  -- Open a new tab (or vsplit based on layout config)
  if cfg.diff.layout == "vsplit" then
    vim.cmd("vsplit")
  else
    vim.cmd("tabnew")
  end
  diff_tab = vim.api.nvim_get_current_tabpage()

  -- Left side: CURRENT (original file content)
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, read_file_lines(original_path))
  vim.bo[orig_buf].buftype    = "nofile"
  vim.bo[orig_buf].bufhidden  = "wipe"
  vim.bo[orig_buf].swapfile   = false
  vim.bo[orig_buf].modifiable = false
  if ft ~= "" then vim.bo[orig_buf].filetype = ft end

  local orig_win = vim.api.nvim_get_current_win()
  vim.wo[orig_win].winbar = "%#DiagnosticError# " .. labels.current .. " %* " .. display_name
  vim.api.nvim_win_set_hl_ns(orig_win, current_ns)
  vim.cmd("diffthis")

  -- Right side: PROPOSED (what Claude wants to write)
  vim.cmd("rightbelow vsplit")
  local prop_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, prop_buf)
  vim.api.nvim_buf_set_lines(prop_buf, 0, -1, false, read_file_lines(proposed_path))
  vim.bo[prop_buf].buftype    = "nofile"
  vim.bo[prop_buf].bufhidden  = "wipe"
  vim.bo[prop_buf].swapfile   = false
  vim.bo[prop_buf].modifiable = false
  if ft ~= "" then vim.bo[prop_buf].filetype = ft end

  local prop_win = vim.api.nvim_get_current_win()
  vim.wo[prop_win].winbar = "%#DiagnosticWarn# " .. labels.proposed .. " %* " .. display_name
  vim.api.nvim_win_set_hl_ns(prop_win, proposed_ns)
  vim.cmd("diffthis")

  diff_bufs = { orig_buf, prop_buf }

  -- Show the full file (like VS Code diff) — open all folds
  if cfg.diff.full_file then
    for _, win in ipairs({ orig_win, prop_win }) do
      vim.wo[win].foldenable  = true
      vim.wo[win].foldmethod  = "diff"
      vim.wo[win].foldlevel   = 999
      vim.wo[win].foldcolumn  = "0"
    end
  end

  -- Equalize window widths to 50/50
  if cfg.diff.equalize then
    vim.cmd("wincmd =")
  end

  -- Re-equalize when terminal is resized (e.g. tmux pane zoom/unzoom)
  diff_augroup = vim.api.nvim_create_augroup("CodePreviewDiffResize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = diff_augroup,
    callback = function()
      if cfg.diff.equalize
        and diff_tab
        and vim.api.nvim_tabpage_is_valid(diff_tab)
        and vim.api.nvim_get_current_tabpage() == diff_tab
      then
        vim.cmd("wincmd =")
      end
    end,
  })

  -- Jump to first diff change
  vim.cmd("normal! ]c")
end

function M.close_diff()
  if diff_tab and vim.api.nvim_tabpage_is_valid(diff_tab) then
    local wins = vim.api.nvim_tabpage_list_wins(diff_tab)
    -- Turn off diff mode first to avoid triggering DiffUpdated autocmds
    -- during window close (works around Neovim crash in win_findbuf when
    -- w_buffer is NULL during frame recalculation)
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_call, win, function() vim.cmd('diffoff') end)
      end
    end
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  for _, buf in ipairs(diff_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  if diff_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, diff_augroup)
    diff_augroup = nil
  end

  diff_tab  = nil
  diff_bufs = {}
  diff_file_path = nil
  inline_line_numbers = {}
  inline_line_types = {}
  inline_diff_win = nil

  -- If there's a queued diff, show it now
  if #diff_queue > 0 then
    local next_diff = table.remove(diff_queue, 1)
    M.show_diff_from_lines(next_diff.orig_lines, next_diff.prop_lines,
                           next_diff.real_file_path, next_diff.abs_file_path)
  end
end

--- Show a diff from pre-read line arrays (used by the queue).
--- Writes lines to temp files then delegates to show_diff().
function M.show_diff_from_lines(orig_lines, prop_lines, real_file_path, abs_file_path)
  local tmpdir = os.getenv("TMPDIR") or "/tmp"
  local orig_path = tmpdir .. "/claude-diff-original"
  local prop_path = tmpdir .. "/claude-diff-proposed"
  local f = io.open(orig_path, "w")
  if f then f:write(table.concat(orig_lines, "\n")); if #orig_lines > 0 then f:write("\n") end; f:close() end
  f = io.open(prop_path, "w")
  if f then f:write(table.concat(prop_lines, "\n")); if #prop_lines > 0 then f:write("\n") end; f:close() end
  M.show_diff(orig_path, prop_path, real_file_path, abs_file_path)
end

-- Close diff AND clear neo-tree indicators (for manual close via <leader>dq)
function M.close_diff_and_clear()
  diff_queue = {}  -- discard pending diffs on manual close
  M.close_diff()
  pcall(function() require("code-preview.changes").clear_all() end)
  pcall(function() require("code-preview.neo_tree").refresh() end)
end

return M
