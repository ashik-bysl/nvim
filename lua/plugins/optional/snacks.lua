return {
  {
    "folke/snacks.nvim",
    opts = {
      explorer = {
        enabled = true,
        replace_netrw = true,
      },

      picker = {
        sources = {
          explorer = {
            -- Keep Explorer alive when switching back to editor.
            auto_close = false,
            -- diagonostics = false,
            -- Explorer normally works from the list window.
            focus = "list",

            hidden = true,
            ignored = true,

            -- Keep useful dotfiles visible, but hide Git internals.
            exclude = {
              ".git",
            },

            layout = {
              preset = "sidebar",
              -- The sidebar preset defaults to 40 columns; keep it 15% narrower.
              layout = {
                width = 35,
                min_width = 35,
              },
            },
          },
        },
      },
    },
  },
}
