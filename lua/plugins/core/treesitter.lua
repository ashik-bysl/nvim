local function add_unique(list, value)
  if not vim.tbl_contains(list, value) then
    table.insert(list, value)
  end
end
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      local parsers = {
        "bash",
        "html",
        "javascript",
        "json",
        "json5",
        "jsonc",
        "lua",
        "markdown",
        "markdown_inline",
        "python",
        "go",
        "gomod",
        "gosum",
        "gowork",
        "rust",
        "ron",
        "query",
        "regex",
        "tsx",
        "typescript",
        "vim",
        "vimdoc",
        "yaml",
      }
      for _, parser in ipairs(parsers) do
        add_unique(opts.ensure_installed, parser)
      end
    end,
  },
}
