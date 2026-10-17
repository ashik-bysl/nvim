return {
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters_by_ft = {
        bash = { "shellcheck" },
        python = { "flake8" },
        sh = { "shellcheck" },
      },
    },
  },
}
