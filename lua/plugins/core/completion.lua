local function add_unique(list, value)
  if not vim.tbl_contains(list, value) then
    table.insert(list, value)
  end
end
return {
  {
    "saghen/blink.cmp",
    dependencies = { "moyiz/blink-emoji.nvim" },
    opts = function(_, opts)
      opts.sources = opts.sources or {}
      opts.sources.default = opts.sources.default or { "lsp", "path", "snippets", "buffer" }
      add_unique(opts.sources.default, "emoji")
      opts.sources.providers = opts.sources.providers or {}
      opts.sources.providers.emoji =
        { name = "Emoji", module = "blink-emoji", score_offset = 15, opts = { insert = true } }
    end,
  },
}
