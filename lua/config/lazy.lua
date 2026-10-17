local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"

  local out = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    lazyrepo,
    lazypath,
  })

  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})

    vim.fn.getchar()
    os.exit(1)
  end
end

vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    -- LazyVim loads enabled extras from lazyvim.json.
    {
      "LazyVim/LazyVim",
      import = "lazyvim.plugins",
    },
    {
      import = "plugins",
    },
  },

  defaults = {
    -- New plugins need a load trigger (event, command, filetype, or key).
    -- Overrides inherit the trigger from LazyVim's plugin spec.
    lazy = true,

    -- Use the latest plugin commit instead of potentially outdated releases.
    version = false,
  },

  install = {
    colorscheme = {
      "oxocarbon",
    },
  },

  checker = {
    enabled = true,
    notify = false,
  },

  performance = {
    rtp = {
      disabled_plugins = {
        "gzip",
        "matchit",
        -- "matchparen",
        -- "netrwPlugin",
        -- "tarPlugin",
        "tohtml",
        "tutor",
        "zipPlugin",
      },
    },
  },
})
