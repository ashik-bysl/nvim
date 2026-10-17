local features = require("config.features")

local specs = {
  { import = "plugins.core" },
  { import = "plugins.editor" },
  { import = "plugins.languages" },
}

if features.custom_explorer then
  table.insert(specs, { import = "plugins.optional.snacks" })
  table.insert(specs, { import = "plugins.optional.explorer" })
end

if features.database then
  table.insert(specs, { import = "plugins.optional.database" })
end

if features.lazygit then
  table.insert(specs, { import = "plugins.optional.lazygit" })
end

return specs
