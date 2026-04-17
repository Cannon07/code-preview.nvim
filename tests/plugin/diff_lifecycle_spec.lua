-- diff_lifecycle_spec.lua — Tests for the diff module lifecycle

local diff = require("code-preview.diff")
local changes = require("code-preview.changes")

-- Helper: write a temp file with content and return the path
local function tmp_file(name, content)
  local path = vim.fn.tempname() .. "_" .. name
  local f = io.open(path, "w")
  f:write(content)
  f:close()
  return path
end

describe("diff lifecycle", function()
  before_each(function()
    changes.clear_all()
    diff.close_diff()
  end)

  it("show_diff opens a diff tab", function()
    local orig = tmp_file("orig.txt", "line one\nline two\nline three")
    local prop = tmp_file("prop.txt", "line one\nline TWO\nline three\nline four")

    diff.show_diff(orig, prop, "test.txt")
    assert.is_true(diff.is_open())

    os.remove(orig)
    os.remove(prop)
  end)

  it("close_diff closes the tab", function()
    local orig = tmp_file("orig2.txt", "hello")
    local prop = tmp_file("prop2.txt", "world")

    diff.show_diff(orig, prop, "test2.txt")
    assert.is_true(diff.is_open())

    diff.close_diff()
    assert.is_false(diff.is_open())

    os.remove(orig)
    os.remove(prop)
  end)

  it("show_diff replaces an existing diff", function()
    local orig1 = tmp_file("a_orig.txt", "aaa")
    local prop1 = tmp_file("a_prop.txt", "bbb")
    local orig2 = tmp_file("b_orig.txt", "ccc")
    local prop2 = tmp_file("b_prop.txt", "ddd")

    diff.show_diff(orig1, prop1, "a.txt")
    assert.is_true(diff.is_open())

    diff.show_diff(orig2, prop2, "b.txt")
    assert.is_true(diff.is_open())

    os.remove(orig1)
    os.remove(prop1)
    os.remove(orig2)
    os.remove(prop2)
  end)

  it("is_open returns false with no active diff", function()
    diff.close_diff()
    assert.is_false(diff.is_open())
  end)

  it("close_diff_and_clear clears changes too", function()
    local orig = tmp_file("clear_orig.txt", "x")
    local prop = tmp_file("clear_prop.txt", "y")

    changes.set("/tmp/some_file.lua", "modified")
    diff.show_diff(orig, prop, "clear.txt")

    assert.equals(1, vim.tbl_count(changes.get_all()))

    diff.close_diff_and_clear()

    assert.is_false(diff.is_open())
    assert.equals(0, vim.tbl_count(changes.get_all()))

    os.remove(orig)
    os.remove(prop)
  end)

  it("is_open with file_path only matches the tagged file", function()
    local orig = tmp_file("tag_orig.txt", "aaa")
    local prop = tmp_file("tag_prop.txt", "bbb")

    -- Pass abs_file_path as 4th arg to tag the diff
    diff.show_diff(orig, prop, "tag.txt", "/abs/path/tag.txt")

    assert.is_true(diff.is_open())                    -- no arg: any diff is open
    assert.is_true(diff.is_open("/abs/path/tag.txt")) -- matching file
    assert.is_false(diff.is_open("/abs/path/other.txt")) -- different file

    diff.close_diff()
    os.remove(orig)
    os.remove(prop)
  end)

  it("show_diff opens multiple tabs for different files simultaneously", function()
    local orig1 = tmp_file("q_orig1.txt", "file1 original")
    local prop1 = tmp_file("q_prop1.txt", "file1 proposed")
    local orig2 = tmp_file("q_orig2.txt", "file2 original")
    local prop2 = tmp_file("q_prop2.txt", "file2 proposed")

    -- Open diff for file1
    diff.show_diff(orig1, prop1, "file1.txt", "/abs/file1.txt")
    assert.is_true(diff.is_open("/abs/file1.txt"))

    -- Show diff for file2 while file1 is open — both should be active
    diff.show_diff(orig2, prop2, "file2.txt", "/abs/file2.txt")
    assert.is_true(diff.is_open("/abs/file1.txt"))  -- file1 still open
    assert.is_true(diff.is_open("/abs/file2.txt"))  -- file2 also open

    -- Close file1's diff — file2 should remain
    diff.close_for_file("/abs/file1.txt")
    assert.is_false(diff.is_open("/abs/file1.txt"))
    assert.is_true(diff.is_open("/abs/file2.txt"))

    -- Close file2
    diff.close_for_file("/abs/file2.txt")
    assert.is_false(diff.is_open())

    os.remove(orig1)
    os.remove(prop1)
    os.remove(orig2)
    os.remove(prop2)
  end)

  it("close_for_file leaves no stale tabpage references", function()
    local orig = tmp_file("stale_orig.txt", "before")
    local prop = tmp_file("stale_prop.txt", "after")

    diff.show_diff(orig, prop, "stale.txt", "/abs/stale.txt")
    assert.is_true(diff.is_open("/abs/stale.txt"))

    -- Record the tab handle before closing
    local tab_before = nil
    for _, entry in pairs(diff._active_diffs()) do
      tab_before = entry.tab
    end
    assert.is_not_nil(tab_before)

    diff.close_for_file("/abs/stale.txt")

    -- The diff must be gone from the active set
    assert.is_false(diff.is_open("/abs/stale.txt"))

    -- The tab must no longer be valid (no stale tabpage reference)
    assert.is_false(vim.api.nvim_tabpage_is_valid(tab_before))

    os.remove(orig)
    os.remove(prop)
  end)

  it("close_diff_and_clear closes all active diffs", function()
    local orig1 = tmp_file("drain_orig1.txt", "aaa")
    local prop1 = tmp_file("drain_prop1.txt", "bbb")
    local orig2 = tmp_file("drain_orig2.txt", "ccc")
    local prop2 = tmp_file("drain_prop2.txt", "ddd")

    diff.show_diff(orig1, prop1, "drain1.txt", "/abs/drain1.txt")
    diff.show_diff(orig2, prop2, "drain2.txt", "/abs/drain2.txt")

    assert.is_true(diff.is_open("/abs/drain1.txt"))
    assert.is_true(diff.is_open("/abs/drain2.txt"))

    -- close_diff_and_clear should close both diffs
    diff.close_diff_and_clear()
    assert.is_false(diff.is_open())

    os.remove(orig1)
    os.remove(prop1)
    os.remove(orig2)
    os.remove(prop2)
  end)
end)

describe("diff layouts", function()
  -- Temporarily override the diff layout for one test, restoring it afterwards.
  local function with_layout(layout, fn)
    local saved = require("code-preview").config.diff.layout
    require("code-preview").config.diff.layout = layout
    local ok, err = pcall(fn)
    require("code-preview").config.diff.layout = saved
    if not ok then error(err, 2) end
  end

  before_each(function()
    changes.clear_all()
    diff.close_diff()
  end)

  it("tab layout creates a new tab with two side-by-side windows", function()
    local orig = tmp_file("tab_orig.txt", "line1\nline2")
    local prop = tmp_file("tab_prop.txt", "line1\nchanged")

    local tabs_before = #vim.api.nvim_list_tabpages()

    with_layout("tab", function()
      diff.show_diff(orig, prop, "layout_tab.txt")
    end)

    assert.is_true(diff.is_open())
    -- A new tab should have been opened
    assert.equals(tabs_before + 1, #vim.api.nvim_list_tabpages())
    -- The diff tab should have exactly 2 windows: CURRENT and PROPOSED
    local diff_tabpage = vim.api.nvim_get_current_tabpage()
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(diff_tabpage))

    diff.close_diff()
    os.remove(orig)
    os.remove(prop)
  end)

  it("vsplit layout opens two windows in the current tab without creating a new tab", function()
    local orig = tmp_file("vs_orig.txt", "alpha\nbeta")
    local prop = tmp_file("vs_prop.txt", "alpha\ngamma")

    local tabs_before = #vim.api.nvim_list_tabpages()

    with_layout("vsplit", function()
      diff.show_diff(orig, prop, "layout_vsplit.txt")
    end)

    assert.is_true(diff.is_open())
    -- vsplit must NOT open a new tab
    assert.equals(tabs_before, #vim.api.nvim_list_tabpages())

    diff.close_diff()
    os.remove(orig)
    os.remove(prop)
  end)

  it("inline layout creates a new tab with a single buffer (no side-by-side split)", function()
    local orig = tmp_file("il_orig.txt", "hello\nworld")
    local prop = tmp_file("il_prop.txt", "hello\nearth")

    local tabs_before = #vim.api.nvim_list_tabpages()

    with_layout("inline", function()
      diff.show_diff(orig, prop, "layout_inline.txt")
    end)

    assert.is_true(diff.is_open())
    -- inline also opens in a new tab
    assert.equals(tabs_before + 1, #vim.api.nvim_list_tabpages())
    -- But only ONE window — no CURRENT/PROPOSED split
    local diff_tabpage = vim.api.nvim_get_current_tabpage()
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(diff_tabpage))

    diff.close_diff()
    os.remove(orig)
    os.remove(prop)
  end)
end)
