return {
  {
    "mason-org/mason.nvim",
    opts = { ensure_installed = { "graphql-language-service-cli" } },
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "graphql" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = { servers = { graphql = {} } },
  },
  {
    "stevearc/conform.nvim",
    opts = { formatters_by_ft = { graphql = { "prettier" } } },
  },
}
