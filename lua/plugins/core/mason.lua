local function add_unique(list, value)
  if not vim.tbl_contains(list, value) then
    table.insert(list, value)
  end
end
return {
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      local tools = { "stylua", "shellcheck", "shfmt", "flake8" }
      for _, tool in ipairs(tools) do
        add_unique(opts.ensure_installed, tool)
      end
    end,
  },
}
