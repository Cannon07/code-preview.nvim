-- minimal_init.lua — Minimal Neovim config for plenary busted tests
--
-- Sets up the runtime path with plenary.nvim and the plugin under test.
-- Used by: nvim --headless -c "PlenaryBustedDirectory tests/plugin/"

-- Add the plugin under test
vim.opt.rtp:append(".")

-- Add plenary.nvim (cloned to deps/ by run_lua.sh or CI)
local deps_dir = vim.fn.fnamemodify("deps", ":p")
vim.opt.rtp:append(deps_dir .. "plenary.nvim")

vim.opt.swapfile = false
vim.cmd("runtime! plugin/plenary.vim")

-- Load the plugin
require("code-preview").setup()
