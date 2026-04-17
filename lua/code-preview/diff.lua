local M = {}

-- Active diffs keyed by absolute file path.
-- Each entry: { tab, bufs, augroup, inline_win }
local active_diffs = {}

-- Per-buffer inline diff state (line numbers, types) for statuscolumn.
-- Keyed by buffer handle.
local buf_inline_data = {}

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

-- Update neo-tree indicator + reveal for a file that's about to be previewed.
local function mark_change_and_reveal(abs_file_path)
  if not abs_file_path or abs_file_path == "" then
    return
  end

  local status = vim.loop.fs_stat(abs_file_path) and "modified" or "created"
  pcall(function() require("code-preview.changes").set(abs_file_path, status) end)
  pcall(function() require("code-preview.neo_tree").refresh() end)

  local cfg = require("code-preview").config
  if not (cfg and cfg.neo_tree and cfg.neo_tree.reveal ~= false) then
    return
  end

  local reveal_dir = nil
  if cfg.neo_tree.reveal_root == "git" then
    local parent = vim.fn.fnamemodify(abs_file_path, ":h")
    local git_out = vim.fn.systemlist(
      "git -C " .. vim.fn.shellescape(parent) .. " rev-parse --show-toplevel 2>/dev/null"
    )
    if vim.v.shell_error == 0 and git_out[1] and git_out[1] ~= "" then
      reveal_dir = git_out[1]
    end
  end

  local reveal_target = abs_file_path
  if status == "created" then
    local parent = vim.fn.fnamemodify(abs_file_path, ":h")
    while parent ~= "/" and vim.fn.isdirectory(parent) == 0 do
      parent = vim.fn.fnamemodify(parent, ":h")
    end
    local siblings = vim.fn.glob(parent .. "/*", false, true)
    reveal_target = siblings[1] or parent
  end

  vim.defer_fn(function()
    pcall(function()
      require("code-preview.neo_tree").reveal(reveal_target, reveal_dir)
    end)
  end, 300)
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

--- Count how many active diffs are currently open.
local function active_count()
  local n = 0
  for _ in pairs(active_diffs) do n = n + 1 end
  return n
end

function M.is_open(file_path)
  if file_path and file_path ~= "" then
    local entry = active_diffs[file_path]
    if entry and entry.tab and vim.api.nvim_tabpage_is_valid(entry.tab) then
      return true
    end
    return false
  end
  -- No file_path: return true if ANY diff is open
  return active_count() > 0
end

-- Statuscolumn function for inline diff: shows old|new line numbers + sign.
-- Reads per-buffer state from buf_inline_data so multiple inline diffs coexist.
function M.inline_statuscolumn(col_width)
  local win = vim.g.statusline_winid
  local buf = vim.api.nvim_win_get_buf(win)
  local data = buf_inline_data[buf]
  if not data then
    return ""
  end
  local lnum = vim.v.lnum
  local line_numbers = data.line_numbers
  local line_types = data.line_types
  if not line_numbers[lnum] then
    return string.rep(" ", col_width * 2 + 3)
  end
  local old_num = line_numbers[lnum][1]
  local new_num = line_numbers[lnum][2]
  local old_str = old_num and string.format("%" .. col_width .. "d", old_num) or string.rep(" ", col_width)
  local new_str = new_num and string.format("%" .. col_width .. "d", new_num) or string.rep(" ", col_width)

  local line_type = line_types[lnum]
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
  local prefix = 0
  local min_len = math.min(#old_line, #new_line)
  while prefix < min_len and old_line:byte(prefix + 1) == new_line:byte(prefix + 1) do
    prefix = prefix + 1
  end
  local suffix = 0
  while suffix < (min_len - prefix)
    and old_line:byte(#old_line - suffix) == new_line:byte(#new_line - suffix) do
    suffix = suffix + 1
  end
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
  local line_highlights = {}
  local char_highlights = {}
  local line_numbers = {}
  local line_types = {}

  local entries = {}
  for line in diff_str:gmatch("([^\n]*)\n?") do
    if line:sub(1, 3) == "---" or line:sub(1, 3) == "+++" then
      -- skip
    elseif line:sub(1, 2) == "@@" then
      -- skip hunk headers
    elseif line:sub(1, 1) == "-" then
      table.insert(entries, { type = "removed", text = line:sub(2) })
    elseif line:sub(1, 1) == "+" then
      table.insert(entries, { type = "added", text = line:sub(2) })
    elseif line ~= "" or #entries > 0 then
      local content = line:sub(1, 1) == " " and line:sub(2) or line
      table.insert(entries, { type = "context", text = content })
    end
  end

  local old_num = 0
  local new_num = 0
  local i = 1
  while i <= #entries do
    local e = entries[i]
    if e.type == "removed" then
      local removed_start = i
      while i <= #entries and entries[i].type == "removed" do
        i = i + 1
      end
      local removed_end = i - 1
      local added_start = i
      while i <= #entries and entries[i].type == "added" do
        i = i + 1
      end
      local added_end = i - 1

      for j = removed_start, removed_end do
        table.insert(display_lines, entries[j].text)
        local line_idx = #display_lines - 1
        old_num = old_num + 1
        table.insert(line_numbers, { old_num, nil })
        table.insert(line_highlights, { line_idx, "ClaudeDiffInlineRemoved" })
        line_types[line_idx + 1] = "removed"
        local pair_idx = added_start + (j - removed_start)
        if pair_idx <= added_end then
          local old_content = entries[j].text
          local new_content = entries[pair_idx].text
          local pfx, old_end, _ = char_diff_ranges(old_content, new_content)
          if old_end > pfx then
            table.insert(char_highlights, { line_idx, "ClaudeDiffInlineRemovedText", pfx, old_end })
          end
        end
      end
      for j = added_start, added_end do
        table.insert(display_lines, entries[j].text)
        local line_idx = #display_lines - 1
        new_num = new_num + 1
        table.insert(line_numbers, { nil, new_num })
        table.insert(line_highlights, { line_idx, "ClaudeDiffInlineAdded" })
        line_types[line_idx + 1] = "added"
        local pair_idx = removed_start + (j - added_start)
        if pair_idx <= removed_end then
          local old_content = entries[pair_idx].text
          local new_content = entries[j].text
          local pfx, _, new_end = char_diff_ranges(old_content, new_content)
          if new_end > pfx then
            table.insert(char_highlights, { line_idx, "ClaudeDiffInlineAddedText", pfx, new_end })
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

--- Create an inline diff tab and return {tab, bufs, inline_win}.
local function show_inline_diff(original_path, proposed_path, real_file_path, cfg)
  apply_inline_highlights(cfg)

  local display_name = real_file_path or "unknown"
  local ft = vim.filetype.match({ filename = real_file_path }) or ""
  local display_lines, line_highlights, char_highlights, line_numbers, line_types =
    build_inline_diff(original_path, proposed_path)

  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
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

  -- Store per-buffer inline data for statuscolumn
  buf_inline_data[buf] = {
    line_numbers = line_numbers,
    line_types = line_types,
  }

  local max_num = 0
  for _, nums in ipairs(line_numbers) do
    if nums[1] and nums[1] > max_num then max_num = nums[1] end
    if nums[2] and nums[2] > max_num then max_num = nums[2] end
  end
  local col_width = math.max(#tostring(max_num), 1)

  local n = active_count()
  local winbar_prefix = n > 0
    and string.format("%%#DiagnosticInfo# DIFF [%d pending] %%* ", n + 1)
    or "%#DiagnosticInfo# INLINE DIFF %* "
  vim.wo[win].winbar = winbar_prefix .. display_name
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = "%!v:lua.require('code-preview.diff').inline_statuscolumn(" .. col_width .. ")"

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

  if first_change_line then
    vim.api.nvim_win_set_cursor(win, { first_change_line, 0 })
  end

  return { tab = tab, bufs = { buf }, inline_win = win }
end

function M.show_diff(original_path, proposed_path, real_file_path, abs_file_path)
  local file_key = abs_file_path or real_file_path
  -- If a diff for this SAME file is already open, close it first (re-edit)
  if file_key and active_diffs[file_key] then
    M.close_for_file(file_key)
  end

  -- Set the neo-tree indicator + reveal
  mark_change_and_reveal(abs_file_path)

  local cfg = require("code-preview").config

  -- Inline layout
  if cfg.diff.layout == "inline" then
    local result = show_inline_diff(original_path, proposed_path, real_file_path, cfg)
    active_diffs[file_key] = result
    -- Force terminal redraw via timer so RPC-triggered tab creation is visible
    vim.fn.timer_start(10, function() vim.cmd("redraw!") end)
    return
  end

  -- Side-by-side / tab layout
  apply_highlights(cfg)

  local display_name = real_file_path or "unknown"
  local labels = cfg.diff.labels or { current = "CURRENT", proposed = "PROPOSED" }
  local ft = vim.filetype.match({ filename = real_file_path }) or ""

  if cfg.diff.layout == "vsplit" then
    vim.cmd("vsplit")
  else
    vim.cmd("tabnew")
  end
  local tab = vim.api.nvim_get_current_tabpage()

  -- Left side: CURRENT
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, read_file_lines(original_path))
  vim.bo[orig_buf].buftype    = "nofile"
  vim.bo[orig_buf].bufhidden  = "wipe"
  vim.bo[orig_buf].swapfile   = false
  vim.bo[orig_buf].modifiable = false
  if ft ~= "" then vim.bo[orig_buf].filetype = ft end

  local orig_win = vim.api.nvim_get_current_win()
  local n = active_count()
  local winbar_prefix = n > 0
    and string.format("%%#DiagnosticError# %s [%d pending] %%* ", labels.current, n + 1)
    or "%#DiagnosticError# " .. labels.current .. " %* "
  vim.wo[orig_win].winbar = winbar_prefix .. display_name
  vim.api.nvim_win_set_hl_ns(orig_win, current_ns)
  vim.cmd("diffthis")

  -- Right side: PROPOSED
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

  local bufs = { orig_buf, prop_buf }

  if cfg.diff.full_file then
    for _, win in ipairs({ orig_win, prop_win }) do
      vim.wo[win].foldenable  = true
      vim.wo[win].foldmethod  = "diff"
      vim.wo[win].foldlevel   = 999
      vim.wo[win].foldcolumn  = "0"
    end
  end

  if cfg.diff.equalize then
    vim.cmd("wincmd =")
  end

  local augroup = vim.api.nvim_create_augroup("CodePreviewDiffResize_" .. file_key, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      if cfg.diff.equalize
        and tab
        and vim.api.nvim_tabpage_is_valid(tab)
        and vim.api.nvim_get_current_tabpage() == tab
      then
        vim.cmd("wincmd =")
      end
    end,
  })

  active_diffs[file_key] = { tab = tab, bufs = bufs, augroup = augroup }

  vim.cmd("normal! ]c")

  vim.fn.timer_start(10, function() vim.cmd("redraw!") end)
end

--- Close the diff for a specific file and clean up its resources.
function M.close_for_file(file_path)
  local entry = active_diffs[file_path]
  if not entry then
    return
  end

  -- Clear neo-tree indicator (refresh is deferred until after the tab is closed
  -- to avoid neo-tree walking a stale tabpage id)
  pcall(function() require("code-preview.changes").clear(file_path) end)

  -- Close the tab's windows
  if entry.tab and vim.api.nvim_tabpage_is_valid(entry.tab) then
    local wins = vim.api.nvim_tabpage_list_wins(entry.tab)
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

  -- Delete buffers and clean up inline data
  for _, buf in ipairs(entry.bufs or {}) do
    buf_inline_data[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  -- Clean up augroup
  if entry.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, entry.augroup)
  end

  active_diffs[file_path] = nil

  -- Refresh neo-tree after the tab is fully gone so it doesn't walk a stale tabpage.
  -- The second delayed refresh picks up the real file after the backend writes it to disk.
  vim.schedule(function()
    pcall(function() require("code-preview.neo_tree").refresh() end)
  end)
  vim.defer_fn(function()
    pcall(function() require("code-preview.neo_tree").refresh() end)
  end, 500)
end

--- Legacy close_diff — closes the most recently focused diff tab.
--- Used by backends that don't pass a file path.
function M.close_diff()
  -- Find which active diff is on the current tab
  local current_tab = vim.api.nvim_get_current_tabpage()
  for file_path, entry in pairs(active_diffs) do
    if entry.tab == current_tab then
      M.close_for_file(file_path)
      return
    end
  end
  -- Fallback: close the first one found
  for file_path, _ in pairs(active_diffs) do
    M.close_for_file(file_path)
    return
  end
end

-- Close ALL diffs and clear neo-tree indicators (for manual close via <leader>dq)
function M.close_diff_and_clear()
  -- Collect keys first to avoid modifying table during iteration
  local files = {}
  for file_path, _ in pairs(active_diffs) do
    files[#files + 1] = file_path
  end
  for _, file_path in ipairs(files) do
    M.close_for_file(file_path)
  end
  pcall(function() require("code-preview.changes").clear_all() end)
  pcall(function() require("code-preview.neo_tree").refresh() end)
end

--- Expose active_diffs for testing (read-only copy).
function M._active_diffs()
  local copy = {}
  for k, v in pairs(active_diffs) do
    copy[k] = { tab = v.tab, bufs = v.bufs }
  end
  return copy
end

return M
