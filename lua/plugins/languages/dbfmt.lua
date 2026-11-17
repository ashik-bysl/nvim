-- Local plugin (lua/dbfmt): formats PostgreSQL and NoSQL (MongoDB, JSON, Redis, CQL).
-- Hooked into conform.nvim, so <leader>cf and format-on-save pick it up.

---@type dbfmt.Config
local opts = {
  -- indent = 2,        -- default: follow 'shiftwidth'
  -- line_width = 80,
  -- keyword_case = "upper",
  -- document_style = "auto",
}

-- Filetypes claimed by dbfmt. Kept here (not in lua/dbfmt) so lazy.nvim can
-- use them as load triggers without loading the plugin first.
local filetypes = { "sql", "pgsql", "cqlang", "mongodb", "redis" }

return {
  {
    -- Virtual: the code already lives on the runtimepath (this config's lua/dbfmt).
    -- Do not use `dir = stdpath("config")` here: lazy.nvim merges specs that share
    -- a `dir`, which would fold this plugin into mdpreview.nvim.
    "dbfmt.nvim",
    virtual = true,
    main = "dbfmt",
    ft = filetypes,
    cmd = "DbFormat",
    init = function()
      require("dbfmt").register_filetypes()
    end,
    opts = opts,
  },

  {
    "stevearc/conform.nvim",
    optional = true,
    opts = function(_, o)
      o.formatters = o.formatters or {}
      o.formatters.dbfmt = require("dbfmt").conform

      o.formatters_by_ft = o.formatters_by_ft or {}
      for _, ft in ipairs(filetypes) do
        o.formatters_by_ft[ft] = { "dbfmt" }
      end
    end,
  },
}
