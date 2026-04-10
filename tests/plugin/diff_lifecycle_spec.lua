-- diff_lifecycle_spec.lua — Tests for the diff module lifecycle

local diff = require("claude-preview.diff")
local changes = require("claude-preview.changes")

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

  it("show_diff queues when a diff for a different file is already open", function()
    local orig1 = tmp_file("q_orig1.txt", "file1 original")
    local prop1 = tmp_file("q_prop1.txt", "file1 proposed")
    local orig2 = tmp_file("q_orig2.txt", "file2 original")
    local prop2 = tmp_file("q_prop2.txt", "file2 proposed")

    -- Open diff for file1
    diff.show_diff(orig1, prop1, "file1.txt", "/abs/file1.txt")
    assert.is_true(diff.is_open("/abs/file1.txt"))

    -- Show diff for file2 while file1 is open — should queue, not replace
    diff.show_diff(orig2, prop2, "file2.txt", "/abs/file2.txt")
    assert.is_true(diff.is_open("/abs/file1.txt"))  -- file1 still showing

    -- Close file1's diff — file2 should auto-show from queue
    diff.close_diff()
    assert.is_true(diff.is_open("/abs/file2.txt"))

    -- Close file2
    diff.close_diff()
    assert.is_false(diff.is_open())

    os.remove(orig1)
    os.remove(prop1)
    os.remove(orig2)
    os.remove(prop2)
  end)

  it("close_diff_and_clear discards the queue", function()
    local orig1 = tmp_file("drain_orig1.txt", "aaa")
    local prop1 = tmp_file("drain_prop1.txt", "bbb")
    local orig2 = tmp_file("drain_orig2.txt", "ccc")
    local prop2 = tmp_file("drain_prop2.txt", "ddd")

    diff.show_diff(orig1, prop1, "drain1.txt", "/abs/drain1.txt")
    diff.show_diff(orig2, prop2, "drain2.txt", "/abs/drain2.txt") -- queued

    assert.is_true(diff.is_open("/abs/drain1.txt"))

    -- Manual close should discard the queue — file2 should NOT auto-show
    diff.close_diff_and_clear()
    assert.is_false(diff.is_open())

    os.remove(orig1)
    os.remove(prop1)
    os.remove(orig2)
    os.remove(prop2)
  end)
end)
