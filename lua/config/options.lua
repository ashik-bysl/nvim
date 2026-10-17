-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
vim.opt.background = "dark"
--
-- Use Telescope as LazyVim's picker.
vim.g.lazyvim_picker = "telescope"
-- Use blink.cmp as the completion engine.
vim.g.lazyvim_cmp = "blink.cmp"
-- Use vtsls for TypeScript and JavaScript.
vim.g.lazyvim_ts_lsp = "vtsls"
-- Alternative TypeScript language server:
-- -- vim.g.lazyvim_ts_lsp = "tsgo"
-- Disable unused remote-plugin providers.
vim.g.loaded_node_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_ruby_provider = 0
