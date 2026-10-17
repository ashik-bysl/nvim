# Neovim configuration

This is a [LazyVim](https://lazyvim.github.io/) configuration with local Oxocarbon, Telescope, blink.cmp, Snacks Explorer, and local overrides for TypeScript, Go, Rust, Python, Docker, SQL, Protocol Buffers, and GraphQL.

## Setup

Install Neovim 0.11.2 or newer with LuaJIT, Git, ripgrep, and a C compiler for Treesitter parsers. A Nerd Font improves icons. `lazygit` is needed for the `<leader>gg` shortcut. Node.js is needed for GraphQL and Prettier; the Rust toolchain supplies `rustfmt`. Language servers and other tools can be installed through `:Mason` after startup.

Put this repository at `~/.config/nvim` and run `nvim`. The first launch installs lazy.nvim and the enabled plugins. Run `:checkhealth` if a feature is missing, and `:Lazy` to inspect plugin installation or load state. Plugin versions are recorded in `lazy-lock.json`.

## Where to change things

| File | Purpose |
| --- | --- |
| `lazyvim.json` | Enabled LazyVim extras; use `:LazyExtras` to manage them. |
| `lua/config/options.lua` | Editor choices that must be set before plugins load. |
| `lua/config/features.lua` | Switches for optional local features. |
| `lua/config/lazy.lua` | lazy.nvim bootstrap and shared defaults. |
| `colors/oxocarbon.lua` | Entry point for `:colorscheme oxocarbon`. |
| `lua/oxocarbon/` | Local theme highlights, palette, and color utilities. |
| `lua/lualine/themes/oxocarbon.lua` | Matching statusline theme. |
| `lua/plugins/init.lua` | Imports the core, editor, language, and enabled optional specs. |
| `lua/plugins/{core,editor,languages,optional}/` | Plugin specs and overrides, grouped by purpose. |

The enabled extras are TypeScript, JSON, Telescope, and mini.starter. Local specs add or adjust the theme, completion, explorer, formatting, language servers, Treesitter parsers, database tools, and Git UI.

The formatting module uses Conform with Go imports, Black for Python, rustfmt for Rust, and Prettier for web files. The Proto module uses the Buf CLI for `.proto` completion, diagnostics, navigation, and formatting; it also recognizes Buf configuration files. The GraphQL module adds syntax, completion, diagnostics, and Prettier formatting. GraphQL language services require a project GraphQL config and the `graphql` package. Inspect `:ConformInfo` and `:LspInfo` when a formatter or server does not attach.

To add a plugin, create a Lua file in the relevant `lua/plugins/` group that returns a lazy.nvim spec. New plugins need a load trigger because this configuration sets `defaults.lazy = true`:

```lua
return {
  {
    "owner/plugin-name",
    cmd = "PluginCommand",
    opts = {},
  },
}
```

The `core`, `editor`, and `languages` directories are imported automatically by `lua/plugins/init.lua`. Optional modules are imported individually there. To make another optional module, add its import behind a switch in `lua/config/features.lua`.

For a plugin already provided by LazyVim, add a spec with the same plugin name to merge options or keys; its existing load trigger is inherited. Restart Neovim and inspect `:Lazy` after changing specs. Use `:LazyExtras` for supported language or editor bundles instead of repeating an entire bundle locally.

`lua/config/features.lua` currently enables the custom Explorer behavior, database UI, and LazyGit. Set a switch to `false` to omit that local module. `custom_explorer = false` restores LazyVim's default Snacks Explorer keys and layout. `explorer_open_on_start` controls the automatic sidebar when customization is enabled. Telescope remains the main LazyVim picker, while Snacks provides the file explorer.

## Local shortcuts

| Keys | Action |
| --- | --- |
| `<leader>e` | Focus or open Snacks Explorer. |
| `<leader>E` | Toggle Snacks Explorer. |
| `<leader>fp` | Find files in the plugin installation directory. |
| `<leader>gg` | Open LazyGit. |
| `<leader>D` | Toggle the database UI. |

The explorer also opens after startup without taking editor focus. For the remaining shortcuts and defaults, see [LazyVim's keymap documentation](https://lazyvim.github.io/keymaps).

## Verify changes

From this directory, run:

```sh
nvim -i NONE --headless -c 'luafile scripts/smoke.lua' -c 'qa!'
```

The check verifies that the resolved plugin set, theme, picker, formatter and server specs, parser list, filetypes, and keymaps are coherent. For a manual check after changing language specs, open representative Go, Rust, TypeScript, Python, Dockerfile, SQL, `.proto`, and `.graphql` files; inspect `:LspInfo`, `:Mason`, `:ConformInfo`, completion, diagnostics, and formatting. Python uses Pyright and flake8; shell files use shellcheck and shfmt. Formatting falls back to an LSP when no configured formatter is available.
