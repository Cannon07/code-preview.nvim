local M = {}

-- Resolve plugin root from this file's location
local function plugin_root()
  local src = debug.getinfo(1, "S").source
  local lua_file = src:sub(2)
  local lua_dir = vim.fn.fnamemodify(lua_file, ":h")
  -- Go up three levels: backends/ → code-preview/ → lua/ → plugin root
  return vim.fn.fnamemodify(lua_dir, ":h:h:h")
end

local function scripts_dir() return plugin_root() .. "/backends/codex" end
local function pre_script()  return scripts_dir() .. "/code-preview-diff.sh" end
local function post_script() return scripts_dir() .. "/code-close-diff.sh"  end

local function codex_dir()    return vim.fn.getcwd() .. "/.codex" end
local function hooks_path()   return codex_dir() .. "/hooks.json" end
local function config_path()  return codex_dir() .. "/config.toml" end

-- Markers we use to identify our hook entries when merging with user-authored
-- hooks. The Codex docs allow multiple hooks per event, so we cooperate
-- rather than overwrite. We match by adapter script *path fragment* so the
-- check works for both the pre-hook (code-preview-diff.sh) and the post-hook
-- (code-close-diff.sh) — the latter doesn't share the "code-preview" prefix.
local HOOK_MARKERS = {
  "backends/codex/code-preview-diff.sh",
  "backends/codex/code-close-diff.sh",
}

local function is_our_command(cmd)
  cmd = tostring(cmd or "")
  for _, m in ipairs(HOOK_MARKERS) do
    if cmd:find(m, 1, true) then return true end
  end
  return false
end

-- Parse JSON file. Returns:
--   ok=true,  data=<table>       — file present and parsed
--   ok=true,  data={}            — file missing or empty (treat as fresh)
--   ok=false, err=<string>       — file present but invalid JSON
-- Distinguishing "missing" from "invalid" matters for install: a corrupted
-- hooks.json should NOT be silently overwritten (data loss).
local function read_json(path)
  if vim.fn.filereadable(path) == 0 then
    return true, {}
  end
  local f = io.open(path, "r")
  if not f then
    return true, {}
  end
  local raw = f:read("*a") or ""
  f:close()
  if raw == "" then return true, {} end
  local ok, data = pcall(vim.json.decode, raw)
  if not ok then
    return false, tostring(data)
  end
  return true, data or {}
end

local function write_json(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"), "Cannot write to " .. path)
  f:write(vim.json.encode(data))
  f:close()
end

-- Filter out hook entries whose command contains our marker, so install is
-- idempotent and uninstall doesn't touch user-authored entries.
local function remove_ours(list)
  local filtered = {}
  for _, entry in ipairs(list or {}) do
    local keep = true
    for _, h in ipairs(entry.hooks or {}) do
      if is_our_command(h.command) then
        keep = false
        break
      end
    end
    if keep then table.insert(filtered, entry) end
  end
  return filtered
end

-- Check both the project-local and global config.toml for the codex_hooks
-- feature flag. Returns "enabled" | "disabled" | "missing".
--   enabled  — at least one location has `codex_hooks = true`
--   disabled — at least one location exists, but none enable the flag
--   missing  — neither location exists
-- The global path mirrors what Codex itself reads, so a user who set the
-- flag in ~/.codex/config.toml shouldn't see a false warning here.
local function file_flag_state(path)
  if vim.fn.filereadable(path) == 0 then return "missing" end
  local f = io.open(path, "r")
  if not f then return "missing" end
  local content = f:read("*a") or ""
  f:close()
  -- Look for `codex_hooks = true` (loose match — handles whitespace & quotes
  -- but not deeply parsed; users with exotic TOML are responsible for it).
  if content:match("codex_hooks%s*=%s*true") then
    return "enabled"
  end
  return "disabled"
end

local function global_config_path()
  -- Test-only override: lets tests redirect the global path away from the
  -- user's real ~/.codex/config.toml. Production callers don't set this.
  local override = vim.env.CODE_PREVIEW_CODEX_GLOBAL_CONFIG
  if override and override ~= "" then return override end
  return vim.fn.expand("~/.codex/config.toml")
end

local function feature_flag_state()
  local local_state  = file_flag_state(config_path())
  local global_state = file_flag_state(global_config_path())
  -- Enabled wins if either location turns it on.
  if local_state == "enabled" or global_state == "enabled" then
    return "enabled"
  end
  -- If at least one file exists but neither enables the flag, surface as
  -- disabled (so we tell the user what to fix). Only report missing when
  -- both files are absent.
  if local_state == "missing" and global_state == "missing" then
    return "missing"
  end
  return "disabled"
end

local function ensure_executable(path)
  if vim.fn.filereadable(path) == 0 then
    vim.notify("[code-preview] script not found: " .. path, vim.log.levels.ERROR)
    return false
  end
  vim.fn.system({ "chmod", "+x", path })
  return true
end

function M.install()
  local pre, post = pre_script(), post_script()
  if not (ensure_executable(pre) and ensure_executable(post)) then return end

  vim.fn.mkdir(codex_dir(), "p")

  -- Merge with existing hooks rather than overwrite, since the user may have
  -- their own entries (logging, prompt scrubbing, etc.) and Codex supports
  -- stacking multiple hooks per event. Bail if the existing file is invalid
  -- JSON — overwriting would silently destroy whatever the user had.
  local ok, data_or_err = read_json(hooks_path())
  if not ok then
    vim.notify(
      "[code-preview] Refusing to install: " .. hooks_path()
        .. " is not valid JSON (" .. data_or_err .. "). Fix or delete it, then retry.",
      vim.log.levels.ERROR
    )
    return
  end
  local data = data_or_err
  data.hooks              = data.hooks or {}
  data.hooks.PreToolUse   = remove_ours(data.hooks.PreToolUse)
  data.hooks.PostToolUse  = remove_ours(data.hooks.PostToolUse)

  table.insert(data.hooks.PreToolUse, {
    matcher = "",
    hooks   = { { type = "command", command = pre } },
  })
  table.insert(data.hooks.PostToolUse, {
    matcher = "",
    hooks   = { { type = "command", command = post } },
  })

  write_json(hooks_path(), data)
  vim.notify("[code-preview] Codex hooks installed → " .. hooks_path(), vim.log.levels.INFO)

  -- Codex ignores hooks.json unless `codex_hooks = true` lives under
  -- `[features]` in config.toml. We don't edit config.toml automatically
  -- (TOML editing without a parser is risky); surface a clear nudge instead.
  local state = feature_flag_state()
  if state ~= "enabled" then
    local msg
    if state == "missing" then
      msg = "[code-preview] Codex requires a feature flag to enable hooks. Create "
          .. config_path() .. " with:\n\n  [features]\n  codex_hooks = true\n"
    else
      msg = "[code-preview] Codex requires `codex_hooks = true` under `[features]` in "
          .. config_path() .. ". Add it manually before running Codex."
    end
    vim.notify(msg, vim.log.levels.WARN)
  end
end

function M.uninstall()
  local path = hooks_path()
  local ok, data_or_err = read_json(path)
  if not ok then
    vim.notify(
      "[code-preview] Cannot uninstall: " .. path
        .. " is not valid JSON (" .. data_or_err .. "). Fix or delete it manually.",
      vim.log.levels.ERROR
    )
    return
  end
  local data = data_or_err
  if not data.hooks then
    vim.notify("[code-preview] No Codex hooks found at " .. path, vim.log.levels.WARN)
    return
  end

  data.hooks.PreToolUse  = remove_ours(data.hooks.PreToolUse)
  data.hooks.PostToolUse = remove_ours(data.hooks.PostToolUse)

  -- If the file ends up with empty arrays (or just our entries removed and
  -- nothing else of substance), keep it on disk — the user might be
  -- mid-edit. Don't try to be clever about deleting it.
  write_json(path, data)
  vim.notify("[code-preview] Codex hooks uninstalled from " .. path, vim.log.levels.INFO)
end

-- Exposed so :CodePreviewStatus can report whether the feature flag is set
-- without duplicating the parser.
function M.feature_flag_state() return feature_flag_state() end

-- True iff `path`'s hooks.json contains an entry referencing our adapter
-- script. Used by status display to detect installation without relying on
-- file existence alone.
function M.is_installed()
  local ok, data = read_json(hooks_path())
  if not ok or not data.hooks then return false end
  for _, ev in ipairs({ "PreToolUse", "PostToolUse" }) do
    for _, entry in ipairs(data.hooks[ev] or {}) do
      for _, h in ipairs(entry.hooks or {}) do
        if is_our_command(h.command) then return true end
      end
    end
  end
  return false
end

return M
