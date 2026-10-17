local function check()
  local features = require("config.features")
  local config = require("lazy.core.config")
  local values = require("lazy.core.plugin").values
  local plugins = config.plugins

  assert(not config.spec.errors or #config.spec.errors == 0, vim.inspect(config.spec.errors))
  assert(vim.g.colors_name == "oxocarbon", "Oxocarbon did not load")
  assert(vim.g.lazyvim_picker == "telescope", "Telescope is not the active picker")

  for _, name in ipairs({ "telescope.nvim", "blink.cmp", "nvim-treesitter", "nvim-lspconfig" }) do
    assert(plugins[name], name .. " is missing")
  end

  assert((plugins["vim-dadbod-ui"] ~= nil) == features.database, "database feature mismatch")
  assert((plugins["lazygit.nvim"] ~= nil) == features.lazygit, "LazyGit feature mismatch")

  local parsers = values(plugins["nvim-treesitter"], "opts", false).ensure_installed
  local seen = {}
  for _, parser in ipairs(parsers) do
    assert(not seen[parser], "duplicate Treesitter parser: " .. parser)
    seen[parser] = true
  end
  for _, parser in ipairs({ "go", "gosum", "rust", "ron", "dockerfile", "proto", "graphql" }) do
    assert(seen[parser], parser .. " parser is missing")
  end

  local servers = values(plugins["nvim-lspconfig"], "opts", false).servers
  for _, name in ipairs({ "gopls", "rust_analyzer", "vtsls", "pyright", "dockerls", "buf_ls", "graphql" }) do
    assert(servers[name], name .. " language server is missing")
  end

  local formatters = values(plugins["conform.nvim"], "opts", false).formatters_by_ft
  for filetype, formatter in pairs({
    go = "goimports",
    python = "black",
    rust = "rustfmt",
    proto = "buf",
    graphql = "prettier",
  }) do
    assert(vim.tbl_contains(formatters[filetype] or {}, formatter), filetype .. " formatter is missing")
  end

  local tools = values(plugins["mason.nvim"], "opts", false).ensure_installed
  for _, name in ipairs({ "buf", "graphql-language-service-cli", "prettier", "black", "goimports" }) do
    assert(vim.tbl_contains(tools, name), name .. " tool is missing")
  end

  assert(vim.filetype.match({ filename = "service.proto" }) == "proto", "Proto filetype is missing")
  assert(vim.filetype.match({ filename = "query.graphql" }) == "graphql", "GraphQL filetype is missing")
  assert(vim.filetype.match({ filename = "buf.yaml" }) == "buf-config", "Buf config filetype is missing")

  local linters = values(plugins["nvim-lint"], "opts", false).linters_by_ft
  assert(vim.tbl_contains(linters.python or {}, "flake8"), "Python linting is missing")
  assert(vim.tbl_contains(linters.sh or {}, "shellcheck"), "Shell linting is missing")

  vim.wait(1000, function()
    return vim.fn.maparg("<leader>fp", "n") ~= ""
  end, 10)
  assert(vim.fn.maparg("<leader>fp", "n") ~= "", "Telescope shortcut is missing")

  if features.custom_explorer then
    assert(vim.fn.maparg("<leader>e", "n", false, true).desc == "Explorer Focus", "Explorer shortcut mismatch")
    assert(vim.fn.maparg("<leader>E", "n", false, true).desc == "Explorer Toggle", "Explorer toggle mismatch")
  else
    assert(vim.fn.maparg("<leader>e", "n", false, true).desc ~= "Explorer Focus", "Custom Explorer is still active")
  end

  assert((vim.fn.maparg("<leader>D", "n") ~= "") == features.database, "database shortcut mismatch")
  assert((vim.fn.maparg("<leader>gg", "n") ~= "") == features.lazygit, "LazyGit shortcut mismatch")

  assert(vim.v.errmsg == "", vim.v.errmsg)
  print("Neovim smoke check passed (" .. vim.tbl_count(plugins) .. " plugins)")
end

local ok, err = xpcall(check, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
end
