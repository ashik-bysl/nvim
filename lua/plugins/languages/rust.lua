return {
  -- Rust LSP
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        rust_analyzer = {
          settings = {
            ["rust-analyzer"] = {
              -- Cargo project configuration
              cargo = {
                allTargets = true,
                features = "all",

                buildScripts = {
                  enable = true,
                },
              },

              -- Procedural macros
              procMacro = {
                enable = true,
              },

              -- Run diagnostics on save
              checkOnSave = true,

              -- Use Clippy instead of plain `cargo check`
              check = {
                command = "clippy",
              },

              -- Inlay hints
              inlayHints = {
                chainingHints = {
                  enable = true,
                },

                parameterHints = {
                  enable = true,
                },

                typeHints = {
                  enable = true,
                },

                closingBraceHints = {
                  enable = true,
                  minLines = 20,
                },

                lifetimeElisionHints = {
                  enable = "never",
                  useParameterNames = true,
                },
              },

              -- Completion
              completion = {
                addCallArgumentSnippets = true,
                addCallParenthesis = true,
              },
            },
          },
        },
      },
    },
  },
}
