
return {
  {
    dir = vim.fn.stdpath("config"),
    name = "mdpreview.nvim",
    main = "mdpreview",
    ft = { "markdown" },

    config = function()
      require("mdpreview").setup({
        port = 0,
        debounce_ms = 200,
        poll_ms = 500,
        open_browser = true,
      })

      vim.keymap.set("n", "<leader>mp", function()
        require("mdpreview").toggle()
      end, {
        desc = "Markdown Preview Toggle",
        silent = true,
      })

      vim.keymap.set("n", "<leader>ms", function()
        require("mdpreview").stop()
      end, {
        desc = "Markdown Preview Stop",
        silent = true,
      })
    end,
  },
}

