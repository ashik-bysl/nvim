return {
  {
    "mason-org/mason.nvim",
    opts = {
      ensure_installed = { "black", "goimports", "prettier" },
    },
  },
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        css = { "prettier" },
        html = { "prettier" },
        javascript = { "prettier" },
        javascriptreact = { "prettier" },
        json = { "prettier" },
        json5 = { "prettier" },
        jsonc = { "prettier" },
        ["markdown.mdx"] = { "prettier" },
        markdown = { "prettier" },
        scss = { "prettier" },
        typescript = { "prettier" },
        typescriptreact = { "prettier" },
        yaml = { "prettier" },
        go = { "goimports" },
        python = { "black" },
        rust = { "rustfmt" },
      },
    },
  },
}
