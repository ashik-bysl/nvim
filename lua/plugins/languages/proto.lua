vim.filetype.add({
  filename = {
    ["buf.yaml"] = "buf-config",
    ["buf.gen.yaml"] = "buf-config",
    ["buf.policy.yaml"] = "buf-config",
    ["buf.lock"] = "buf-config",
  },
})
vim.treesitter.language.register("yaml", "buf-config")

return {
  {
    "mason-org/mason.nvim",
    opts = { ensure_installed = { "buf" } },
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "proto" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = { servers = { buf_ls = {} } },
  },
  {
    "stevearc/conform.nvim",
    opts = { formatters_by_ft = { proto = { "buf" } } },
  },
}
