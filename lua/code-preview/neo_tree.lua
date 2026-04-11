local M = {}

local changes = require("code-preview.changes")

-- Guard: all neo-tree interaction goes through pcall
local has_neo_tree = false

-- Prevent infinite redraw loop when injecting virtual nodes
local injecting_virtual = false

-- Track virtual node paths so we can remove them later
local virtual_nodes = {}

local setup_done = false

-- Define a highlight group from config (supports string link or table spec)
local function define_hl(name, hl_config, opts)
  if type(hl_config) == "string" then
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { link = hl_config, default = true }, opts or {}))
  elseif type(hl_config) == "table" then
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", hl_config, opts or {}))
  end
end

-- Hide/restore other tree components while claude changes are pending
local function update_component_visibility(state, has_pending)
  local hide_components = { "git_status", "modified", "diagnostics" }
  for _, comp_name in ipairs(hide_components) do
    local key = "_claude_orig_" .. comp_name
    if has_pending then
      if state.components[comp_name] and not state.components[key] then
        state.components[key] = state.components[comp_name]
        state.components[comp_name] = function() return {} end
      end
    else
      if state.components[key] then
        state.components[comp_name] = state.components[key]
        state.components[key] = nil
      end
    end
  end
end

-- Resolve a node's effective status, checking ancestors for directory deletions
local function resolve_status(lookup, node_path)
  if not node_path then
    return nil
  end
  local status = lookup[node_path]
  if status then
    return status
  end
  -- Check if any ancestor directory is marked as deleted
  for path, s in pairs(lookup) do
    if s == "deleted" and vim.startswith(node_path, path .. "/") then
      return "deleted"
    end
  end
  return nil
end

-- Wrap the name component to color-code changed files
local function wrap_name_component(state)
  if not state.components.name or state.components._claude_name_wrapped then
    return
  end
  local original_name = state.components.name
  state.components._claude_name_wrapped = true
  state.components.name = function(config, node, s)
    local result = original_name(config, node, s)
    if type(result) == "table" then
      local lookup = s.claude_status_lookup or {}
      local status = resolve_status(lookup, node.path)
      if node._claude_virtual or status == "created" then
        result.highlight = "CodePreviewTreeVirtual"
      elseif status == "modified" then
        result.highlight = "CodePreviewTreeModified"
      elseif status == "deleted" then
        result.highlight = "CodePreviewTreeDeleted"
      end
    end
    return result
  end
end

-- Auto-inject claude_status into renderer config for a given node type
local function inject_renderer(state, node_type)
  local renderer = state.renderers and state.renderers[node_type]
  if not renderer then
    return
  end

  -- Check if claude_status is already in the renderer
  for _, comp in ipairs(renderer) do
    if type(comp) == "table" then
      if comp[1] == "claude_status" then
        return
      end
      -- Check inside container content
      if comp[1] == "container" and comp.content then
        for _, inner in ipairs(comp.content) do
          if type(inner) == "table" and inner[1] == "claude_status" then
            return
          end
        end
        -- Inject inside container, before git_status if present
        table.insert(comp.content, { "claude_status", zindex = 20, align = "right" })
        return
      end
    end
  end

  -- No container found, append to end of renderer
  table.insert(renderer, { "claude_status", zindex = 20, align = "right" })
end

-- Inject the claude_status icon component
local function inject_status_component(state, symbols)
  if state.components.claude_status then
    return
  end
  state.components.claude_status = function(config, node, s)
    local lookup = s.claude_status_lookup or {}
    local status = resolve_status(lookup, node.path)
    if node._claude_virtual or status == "created" then
      return {
        text = (symbols.created or "") .. " ",
        highlight = "CodePreviewTreeCreated",
      }
    elseif status == "modified" then
      return {
        text = (symbols.modified or "󰏫") .. " ",
        highlight = "CodePreviewTreeModified",
      }
    elseif status == "deleted" then
      return {
        text = (symbols.deleted or "󰆴") .. " ",
        highlight = "CodePreviewTreeDeleted",
      }
    end
    return {}
  end
end

-- Remove virtual nodes that are no longer in pending changes
local function cleanup_stale_virtual_nodes(state, pending)
  local stale = {}
  for path, _ in pairs(virtual_nodes) do
    if pending[path] ~= "created" then
      table.insert(stale, path)
    end
  end

  local changed = false
  for _, path in ipairs(stale) do
    pcall(function() state.tree:remove_node(path) end)
    virtual_nodes[path] = nil
    changed = true
  end
  return changed
end

-- Inject virtual nodes for created files that don't exist on disk yet
local function inject_virtual_nodes(state, pending)
  local NuiTree = require("nui.tree")
  local changed = false

  for filepath, status in pairs(pending) do
    if status ~= "created" then
      goto continue
    end

    -- Skip if node already exists in tree
    local existing = nil
    pcall(function() existing = state.tree:get_node(filepath) end)
    if existing then
      goto continue
    end

    local parent_path = vim.fn.fnamemodify(filepath, ":h")

    -- Only inject if the parent is within the tree root
    if not vim.startswith(parent_path, state.path) then
      goto continue
    end

    -- Walk up to find the nearest existing parent and its level
    local dirs_to_create = {}
    local current = parent_path
    local base_level = 1
    local skip = false
    while current and #current >= #state.path do
      local pnode = nil
      pcall(function() pnode = state.tree:get_node(current) end)
      if pnode then
        -- Skip if parent dir hasn't lazy-loaded its children yet
        if pnode.loaded == false then
          skip = true
          break
        end
        base_level = (pnode.level or pnode:get_depth()) + 1
        if not pnode:is_expanded() then
          pnode:expand()
        end
        -- Also expand all ancestors up to the tree root so the path is visible
        local ancestor = vim.fn.fnamemodify(current, ":h")
        while ancestor and #ancestor >= #state.path do
          local anode = nil
          pcall(function() anode = state.tree:get_node(ancestor) end)
          if anode and not anode:is_expanded() then
            anode:expand()
          end
          ancestor = vim.fn.fnamemodify(ancestor, ":h")
        end
        break
      end
      table.insert(dirs_to_create, 1, current)
      current = vim.fn.fnamemodify(current, ":h")
    end

    if skip then
      goto continue
    end

    -- Create missing parent directory nodes
    local dir_level = base_level
    for _, dir in ipairs(dirs_to_create) do
      local dir_parent = vim.fn.fnamemodify(dir, ":h")
      local dir_name = vim.fn.fnamemodify(dir, ":t")
      local dir_node = NuiTree.Node({
        id = dir,
        name = dir_name,
        path = dir,
        type = "directory",
        level = dir_level,
        loaded = true,
        is_last_child = true,
        _claude_virtual = true,
      })
      pcall(function()
        state.tree:add_node(dir_node, dir_parent)
        dir_node:expand()
      end)
      dir_level = dir_level + 1
    end

    -- Create the virtual file node
    local name = vim.fn.fnamemodify(filepath, ":t")
    local ext = name:match("%.([^%.]+)$")
    local file_node = NuiTree.Node({
      id = filepath,
      name = name,
      path = filepath,
      type = "file",
      ext = ext,
      level = dir_level,
      is_last_child = true,
      _claude_virtual = true,
    })
    pcall(function()
      state.tree:add_node(file_node, parent_path)
      virtual_nodes[filepath] = true
    end)
    changed = true

    ::continue::
  end

  return changed
end

function M.setup(cfg)
  if setup_done then
    return
  end

  local ok, neo_tree_events = pcall(require, "neo-tree.events")
  if not ok then
    return
  end
  has_neo_tree = true
  setup_done = true

  local symbols = cfg.neo_tree.symbols
  local highlights = cfg.neo_tree.highlights

  -- Define highlight groups from config
  define_hl("CodePreviewTreeModified", highlights.modified)
  define_hl("CodePreviewTreeCreated", highlights.created)
  define_hl("CodePreviewTreeDeleted", highlights.deleted)
  define_hl("CodePreviewTreeVirtual", highlights.created, { italic = true })

  -- Subscribe to BEFORE_RENDER to inject our lookup and components
  neo_tree_events.subscribe({
    event = neo_tree_events.BEFORE_RENDER,
    handler = function(state)
      if not state.components then
        return
      end

      local pending = changes.get_all()
      state.claude_status_lookup = pending

      update_component_visibility(state, next(pending) ~= nil)
      wrap_name_component(state)
      inject_status_component(state, symbols)
      inject_renderer(state, "file")
      inject_renderer(state, "directory")
    end,
  })

  -- After render, inject virtual nodes for new files that don't exist on disk
  neo_tree_events.subscribe({
    event = neo_tree_events.AFTER_RENDER,
    handler = function(state)
      if injecting_virtual then
        return
      end
      if state.name ~= "filesystem" or not state.tree then
        return
      end

      local pending = changes.get_all()
      local needs_redraw = cleanup_stale_virtual_nodes(state, pending)

      if inject_virtual_nodes(state, pending) then
        needs_redraw = true
      end

      if needs_redraw then
        injecting_virtual = true
        pcall(require("neo-tree.ui.renderer").redraw, state)
        injecting_virtual = false
      end
    end,
  })
end

function M.refresh()
  if not has_neo_tree then
    return
  end
  pcall(function()
    require("neo-tree.sources.manager").refresh("filesystem")
  end)
end

function M.reveal(filepath, dir)
  if not has_neo_tree then
    return
  end
  pcall(function()
    local cfg = require("code-preview").config
    local position = cfg.neo_tree.position or "right"
    local opts = {
      action = "show",
      source = "filesystem",
      reveal_file = filepath,
      position = position,
      toggle = false,
    }
    if dir then
      opts.dir = dir
    end
    require("neo-tree.command").execute(opts)
  end)
end

return M
