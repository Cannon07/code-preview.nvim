-- changes_registry_spec.lua — Tests for the changes registry module

local changes = require("code-preview.changes")

describe("changes registry", function()
  before_each(function()
    changes.clear_all()
  end)

  it("set and get a change status", function()
    changes.set("/tmp/file.lua", "modified")
    assert.equals("modified", changes.get("/tmp/file.lua"))
  end)

  it("set overwrites previous status", function()
    changes.set("/tmp/overwrite.lua", "created")
    changes.set("/tmp/overwrite.lua", "modified")
    assert.equals("modified", changes.get("/tmp/overwrite.lua"))
  end)

  it("clear removes a single entry", function()
    changes.set("/tmp/clearme.lua", "deleted")
    changes.clear("/tmp/clearme.lua")
    assert.is_nil(changes.get("/tmp/clearme.lua"))
  end)

  it("clear_all removes all entries", function()
    changes.set("/tmp/a.lua", "modified")
    changes.set("/tmp/b.lua", "created")
    changes.set("/tmp/c.lua", "deleted")
    changes.clear_all()
    assert.equals(0, vim.tbl_count(changes.get_all()))
  end)

  it("clear_by_status removes only matching entries", function()
    changes.set("/tmp/mod.lua", "modified")
    changes.set("/tmp/del1.lua", "deleted")
    changes.set("/tmp/del2.lua", "deleted")
    changes.clear_by_status("deleted")

    assert.equals(1, vim.tbl_count(changes.get_all()))
    assert.equals("modified", changes.get("/tmp/mod.lua"))
  end)

  it("get_all returns all entries", function()
    changes.set("/tmp/x.lua", "modified")
    changes.set("/tmp/y.lua", "created")
    assert.equals(2, vim.tbl_count(changes.get_all()))
  end)
end)
