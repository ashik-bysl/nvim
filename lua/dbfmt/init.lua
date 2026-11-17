-- dbfmt.nvim: format PostgreSQL and NoSQL (MongoDB / JSON documents, Redis, CQL).
--
--   :DbFormat [dialect]      format the buffer, or the selected lines
--   conform.nvim formatter   "dbfmt" (so <leader>cf and format-on-save work)
--   require("dbfmt").format(text, dialect, opts)
--
-- Everything is implemented in Lua; no external formatter is required.

local M = {}

---@class dbfmt.Config
M.config = {
  -- Spaces per indent level. nil follows 'shiftwidth' (or 'tabstop' when it is 0).
  indent = nil,
  line_width = 80,
  -- SQL only: "upper" | "lower" | "preserve"
  keyword_case = "upper",
  -- SQL only: blank lines between statements.
  blank_lines = 1,
  -- Documents: "auto" (JSON expanded, mongo compact) | "compact" | "expanded"
  document_style = "auto",
  -- filetype -> dialect. Remove an entry to stop dbfmt claiming that filetype.
  filetypes = {
    sql = "postgres",
    pgsql = "postgres",
    cqlang = "cql",
    mongodb = "mongo",
    redis = "redis",
  },
  -- Create the :DbFormat command.
  commands = true,
}

local DIALECTS = {
  postgres = { kind = "sql", aliases = { "postgresql", "pg", "pgsql", "psql", "sql" } },
  cql = { kind = "sql", aliases = { "cassandra", "cqlang", "scylla" } },
  mongo = { kind = "doc", aliases = { "mongodb", "mongosh", "nosql" } },
  json = { kind = "doc", aliases = { "jsonc", "json5", "ejson", "ndjson" } },
  redis = { kind = "redis", aliases = {} },
}

local ALIASES = {}
for name, d in pairs(DIALECTS) do
  ALIASES[name] = name
  for _, alias in ipairs(d.aliases) do
    ALIASES[alias] = name
  end
end

---@return string[] names canonical dialect names, sorted
function M.dialects()
  local names = vim.tbl_keys(DIALECTS)
  table.sort(names)
  return names
end

---@param name string|nil
---@return string|nil canonical
function M.resolve(name)
  return name and ALIASES[name:lower()] or nil
end

local function notify(msg, level)
  vim.notify("[dbfmt] " .. msg, level or vim.log.levels.INFO)
end

local function default_indent(buf)
  if M.config.indent then
    return M.config.indent
  end
  buf = buf or 0
  local sw = vim.bo[buf].shiftwidth
  if sw == 0 then
    sw = vim.bo[buf].tabstop
  end
  return sw > 0 and sw or 2
end

---Format text for a dialect.
---@param text string
---@param dialect string canonical name or alias
---@param opts? { indent?: integer, line_width?: integer, keyword_case?: string, style?: string, blank_lines?: integer, buf?: integer }
---@return string|nil formatted
---@return string|nil err
function M.format(text, dialect, opts)
  opts = opts or {}
  local name = M.resolve(dialect)
  if not name then
    return nil, ("unknown dialect '%s' (available: %s)"):format(tostring(dialect), table.concat(M.dialects(), ", "))
  end

  local cfg = M.config
  local common = {
    indent = opts.indent or default_indent(opts.buf),
    line_width = opts.line_width or cfg.line_width,
  }
  local kind = DIALECTS[name].kind

  local ok, formatted, err
  if kind == "sql" then
    common.dialect = name
    common.keyword_case = opts.keyword_case or cfg.keyword_case
    common.blank_lines = opts.blank_lines or cfg.blank_lines
    ok, formatted, err = pcall(require("dbfmt.sql").format, text, common)
  elseif kind == "doc" then
    local style = opts.style or cfg.document_style
    if style == "auto" then
      style = name == "json" and "expanded" or "compact"
    end
    common.style = style
    ok, formatted, err = pcall(require("dbfmt.doc").format, text, common)
  else
    ok, formatted, err = pcall(require("dbfmt.redis").format, text, common)
  end

  if not ok then
    return nil, "internal error: " .. tostring(formatted)
  end
  return formatted, err
end

---Format a list of lines (as stored in a buffer).
---@param lines string[]
---@param dialect string
---@param opts? table
---@return string[]|nil lines
---@return string|nil err
function M.format_lines(lines, dialect, opts)
  local text = table.concat(lines, "\n")
  if not text:find("%S") then
    return lines
  end
  local out, err = M.format(text, dialect, opts)
  if not out then
    return nil, err
  end
  return vim.split(out, "\n", { plain = true })
end

---Format a buffer, or the lines first..last (1-based, inclusive).
---@param buf? integer
---@param dialect? string defaults to the dialect configured for the filetype
---@param first? integer
---@param last? integer
---@return boolean ok
function M.format_buffer(buf, dialect, first, last)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  dialect = dialect or M.config.filetypes[vim.bo[buf].filetype]
  if not dialect then
    notify(
      ("no dialect for filetype '%s'; pass one: %s"):format(vim.bo[buf].filetype, table.concat(M.dialects(), ", ")),
      vim.log.levels.WARN
    )
    return false
  end

  first = first or 1
  last = last or vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)

  local out, err = M.format_lines(lines, dialect, { buf = buf })
  if not out then
    notify(err or "format failed", vim.log.levels.ERROR)
    return false
  end
  if vim.deep_equal(out, lines) then
    return true
  end

  local view = vim.api.nvim_get_current_buf() == buf and vim.fn.winsaveview() or nil
  vim.api.nvim_buf_set_lines(buf, first - 1, last, false, out)
  if view then
    view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(buf))
    vim.fn.winrestview(view)
  end
  return true
end

---conform.nvim formatter definition (registered by lua/plugins/languages/dbfmt.lua).
M.conform = {
  meta = {
    url = "local: lua/dbfmt",
    description = "PostgreSQL / CQL / MongoDB / JSON / Redis formatter written in Lua.",
  },
  format = function(_, ctx, lines, callback)
    local ft = vim.bo[ctx.buf].filetype
    local dialect = M.config.filetypes[ft]
    if not dialect then
      return callback(("dbfmt has no dialect for filetype '%s'"):format(ft))
    end
    local out, err = M.format_lines(lines, dialect, { buf = ctx.buf, indent = M.config.indent or ctx.shiftwidth })
    callback(err, out)
  end,
}

---Filetype detection for the NoSQL file extensions. Cheap; call it at startup.
function M.register_filetypes()
  vim.filetype.add({
    extension = {
      pgsql = "pgsql",
      psql = "pgsql",
      mongodb = "mongodb",
      mongo = "mongodb",
      redis = "redis",
    },
  })
  -- Reuse existing parsers for highlighting.
  pcall(vim.treesitter.language.register, "sql", "pgsql")
  pcall(vim.treesitter.language.register, "javascript", "mongodb")
end

local function create_commands()
  vim.api.nvim_create_user_command("DbFormat", function(args)
    local dialect
    if args.args ~= "" then
      dialect = M.resolve(args.args)
      if not dialect then
        return notify(
          ("unknown dialect '%s' (available: %s)"):format(args.args, table.concat(M.dialects(), ", ")),
          vim.log.levels.ERROR
        )
      end
    end
    local first, last
    if args.range > 0 then
      first, last = args.line1, args.line2
    end
    M.format_buffer(0, dialect, first, last)
  end, {
    nargs = "?",
    range = true,
    desc = "Format SQL (PostgreSQL), CQL, MongoDB, JSON or Redis",
    complete = function(lead)
      local items = {}
      for alias in pairs(ALIASES) do
        if alias:find(lead, 1, true) == 1 then
          items[#items + 1] = alias
        end
      end
      table.sort(items)
      return items
    end,
  })
end

---@param opts? dbfmt.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if M.config.commands then
    create_commands()
  end
end

return M
