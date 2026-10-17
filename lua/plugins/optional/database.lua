local sql_filetypes = {
  "sql",
  "mysql",
  "plsql",
}

-- Disable Neovim's legacy SQL completion implementation.
-- Dadbod completion is provided through blink.cmp.
vim.g.omni_sql_default_compl_type = "syntax"
vim.g.loaded_sql_completion = true

return {
  {
    "tpope/vim-dadbod",
    cmd = "DB",
  },

  {
    "kristijanhusak/vim-dadbod-completion",
    dependencies = {
      "tpope/vim-dadbod",
    },
    ft = sql_filetypes,
  },

  {
    "kristijanhusak/vim-dadbod-ui",
    dependencies = {
      "tpope/vim-dadbod",
    },
    cmd = {
      "DBUI",
      "DBUIToggle",
      "DBUIAddConnection",
      "DBUIFindBuffer",
    },
    keys = {
      {
        "<leader>D",
        "<cmd>DBUIToggle<CR>",
        desc = "Toggle Database UI",
      },
    },
    init = function()
      local data_path = vim.fn.stdpath("data") .. "/dadbod_ui"

      vim.g.db_ui_use_nerd_fonts = 1
      vim.g.db_ui_show_database_icon = true
      vim.g.db_ui_use_nvim_notify = true

      vim.g.db_ui_save_location = data_path
      vim.g.db_ui_tmp_query_location = data_path .. "/tmp"

      -- Prevent potentially expensive queries from running whenever
      -- a query buffer is saved.
      vim.g.db_ui_execute_on_save = false

      vim.g.db_ui_auto_execute_table_helpers = 1
    end,
  },

  {
    "saghen/blink.cmp",
    optional = true,
    dependencies = {
      "kristijanhusak/vim-dadbod-completion",
    },
    opts = function(_, opts)
      opts.sources = opts.sources or {}
      opts.sources.providers = opts.sources.providers or {}
      opts.sources.per_filetype = opts.sources.per_filetype or {}

      opts.sources.providers.dadbod = {
        name = "Dadbod",
        module = "vim_dadbod_completion.blink",
        score_offset = 100,
      }

      for _, filetype in ipairs(sql_filetypes) do
        local sources = opts.sources.per_filetype[filetype] or {}

        sources.inherit_defaults = true

        if not vim.tbl_contains(sources, "dadbod") then
          table.insert(sources, "dadbod")
        end

        opts.sources.per_filetype[filetype] = sources
      end
    end,
  },

  {
    "nvim-treesitter/nvim-treesitter",
    optional = true,
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}

      if not vim.tbl_contains(opts.ensure_installed, "sql") then
        table.insert(opts.ensure_installed, "sql")
      end
    end,
  },
}
