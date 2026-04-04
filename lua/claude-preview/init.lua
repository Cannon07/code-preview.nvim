local M = {}

-- Module-level config, populated by setup()
M.config = {}

local default_config = {
  diff = {
    layout = "tab",        -- "tab", "vsplit", or "inline"
    labels = { current = "CURRENT", proposed = "PROPOSED" },
    auto_close = true,
    equalize = true,
    full_file = true,
    visible_only = false,  -- only show diffs for files open in a visible nvim window
  },
  neo_tree = {
    enabled = true,
    refresh_on_change = true,
    position = "right",
    symbols = {
      modified = "󰏫",
      created  = "󰎔",
      deleted  = "󰆴",
    },
    highlights = {
      modified = { fg = "#e8a838", bold = true },
      created  = { fg = "#56c8d8", bold = true },
      deleted  = { fg = "#e06c75", bold = true, strikethrough = true },
    },
  },
  highlights = {
    current = {
      DiffAdd    = { bg = "#4c2e2e" },
      DiffDelete = { bg = "#4c2e2e" },
      DiffChange = { bg = "#4c3a2e" },
      DiffText   = { bg = "#5c3030" },
    },
    proposed = {
      DiffAdd    = { bg = "#2e4c2e" },
      DiffDelete = { bg = "#4c2e2e" },
      DiffChange = { bg = "#2e3c4c" },
      DiffText   = { bg = "#3e5c3e" },
    },
    inline = {
      added        = { bg = "#2e4c2e" },
      removed      = { bg = "#4c2e2e" },
      added_text   = { bg = "#3a6e3a" },
      removed_text = { bg = "#6e3a3a" },
    },
  },
}

local function deep_merge(base, override)
  local result = vim.deepcopy(base)
  for k, v in pairs(override) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

function M.setup(user_config)
  M.config = deep_merge(default_config, user_config or {})

  vim.api.nvim_create_user_command("ClaudePreviewInstallHooks", function()
    require("claude-preview.hooks").install()
  end, { desc = "Install claude-preview PreToolUse/PostToolUse hooks" })

  vim.api.nvim_create_user_command("ClaudePreviewUninstallHooks", function()
    require("claude-preview.hooks").uninstall()
  end, { desc = "Uninstall claude-preview hooks" })

  vim.api.nvim_create_user_command("CodePreviewInstallOpenCodeHooks", function()
    require("claude-preview.hooks").install_opencode()
  end, { desc = "Install claude-preview plugin for OpenCode" })

  vim.api.nvim_create_user_command("CodePreviewUninstallOpenCodeHooks", function()
    require("claude-preview.hooks").uninstall_opencode()
  end, { desc = "Uninstall claude-preview plugin from OpenCode" })

  vim.api.nvim_create_user_command("ClaudePreviewCloseDiff", function()
    require("claude-preview.diff").close_diff_and_clear()
  end, { desc = "Manually close claude-preview diff (use after rejecting a change)" })

  vim.api.nvim_create_user_command("ClaudePreviewStatus", function()
    M.status()
  end, { desc = "Show claude-preview status" })

  vim.api.nvim_create_user_command("ClaudePreviewToggleVisibleOnly", function()
    M.config.diff.visible_only = not M.config.diff.visible_only
    vim.notify(
      "claude-preview: visible_only = " .. tostring(M.config.diff.visible_only),
      vim.log.levels.INFO,
      { title = "claude-preview" }
    )
  end, { desc = "Toggle visible_only — show diffs only for open buffers vs all files" })

  -- Neo-tree integration (soft dependency)
  if M.config.neo_tree.enabled then
    require("claude-preview.neo_tree").setup(M.config)
  end

  vim.keymap.set("n", "<leader>dq", function()
    require("claude-preview.diff").close_diff_and_clear()
  end, { desc = "Close claude-preview diff" })
end

--- Query hook context for the PreToolUse shell script.
--- Returns a JSON string with config + file visibility in a single RPC call.
--- @param file_path string absolute path of the file being edited
--- @return string JSON: { visible_only, file_visible }
function M.hook_context(file_path)
  local cfg = M.config
  local visible_only = cfg.diff.visible_only and true or false

  local file_visible = false
  if visible_only and file_path ~= "" then
    local is_mac = vim.fn.has("mac") == 1
    local target = vim.uv.fs_realpath(file_path) or vim.fn.fnamemodify(file_path, ":p")
    if is_mac then target = target:lower() end

    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      local name = vim.uv.fs_realpath(vim.api.nvim_buf_get_name(b))
              or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":p")
      if is_mac then name = name:lower() end
      if name == target then
        file_visible = true
        break
      end
    end
  end

  return vim.json.encode({
    visible_only = visible_only,
    file_visible = file_visible,
  })
end

function M.status()
  local lines = { "claude-preview.nvim status", string.rep("─", 40) }

  -- Socket
  local socket = vim.env.NVIM_LISTEN_ADDRESS or ""
  if socket == "" then
    socket = vim.v.servername or ""
  end
  if socket ~= "" then
    table.insert(lines, "Neovim socket : " .. socket)
  else
    table.insert(lines, "Neovim socket : not found")
  end

  -- Hooks installed?
  local settings_path = vim.fn.getcwd() .. "/.claude/settings.local.json"
  local hooks_ok = false
  local f = io.open(settings_path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    hooks_ok = content:find("claude-preview-diff", 1, true) ~= nil
  end
  table.insert(lines, "Hooks         : " .. (hooks_ok and "installed" or "not installed"))

  -- jq dependency
  local jq_ok = vim.fn.executable("jq") == 1
  table.insert(lines, "jq            : " .. (jq_ok and "found" or "MISSING"))

  -- Diff tab open?
  local diff = require("claude-preview.diff")
  table.insert(lines, "Diff tab      : " .. (diff.is_open() and "open" or "closed"))

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "claude-preview" })
end

return M
