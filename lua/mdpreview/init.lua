

local M = {}

local uv = vim.uv or vim.loop

local defaults = {
  port = 0, -- 0 = automatically assign an available port
  debounce_ms = 200,
  poll_ms = 500,
  open_browser = true,
}

local config = vim.deepcopy(defaults)

local state = {
  server = nil,
  timer = nil,
  group = nil,
  buffer = nil,
  port = nil,
  html = "",
  version = 0,
  generation = 0,
  active = false,
  clients = {},
}

local function notify(message, level)
  vim.notify("[mdpreview] " .. message, level or vim.log.levels.INFO)
end

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function browser_html()
  return string.format([=[
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Neovim Markdown Preview</title>

  <style>
    :root {
      color-scheme: dark;
      font-family: system-ui, sans-serif;
      background: #0d1117;
      color: #c9d1d9;
    }

    body {
      max-width: 900px;
      margin: 0 auto;
      padding: 40px 24px 100px;
      line-height: 1.7;
      overflow-wrap: break-word;
    }

    h1, h2 {
      border-bottom: 1px solid #30363d;
      padding-bottom: 0.3em;
    }

    a { color: #58a6ff; }

    pre {
      background: #161b22;
      padding: 16px;
      border-radius: 6px;
      overflow-x: auto;
    }

    code {
      font-family: monospace;
      background: #161b22;
      padding: 2px 5px;
      border-radius: 4px;
    }

    pre code { padding: 0; }

    blockquote {
      border-left: 4px solid #30363d;
      padding-left: 16px;
      margin-left: 0;
      color: #8b949e;
    }

    table {
      border-collapse: collapse;
      width: 100%%;
      display: block;
      overflow-x: auto;
    }

    th, td {
      padding: 8px 14px;
      border: 1px solid #30363d;
    }

    tr:nth-child(even) { background: #161b22; }

    img { max-width: 100%%; }

    hr {
      border: 0;
      border-top: 1px solid #30363d;
    }

    #status {
      position: fixed;
      right: 16px;
      bottom: 12px;
      background: #161b22;
      color: #8b949e;
      font-size: 12px;
      padding: 6px 12px;
      border-radius: 6px;
    }
  </style>
</head>

<body>
  <main id="content">Loading preview...</main>
  <div id="status">Connecting...</div>

  <script>
    let version = -1;
    let pending = false;

    async function refresh() {
      if (pending) return;
      pending = true;

      try {
        const response = await fetch("/content", {
          cache: "no-store"
        });

        if (!response.ok) throw new Error("Preview unavailable");

        const data = await response.json();

        if (data.version !== version) {
          const scrollRatio =
            document.documentElement.scrollHeight > innerHeight
              ? scrollY / (document.documentElement.scrollHeight - innerHeight)
              : 0;

          document.getElementById("content").innerHTML = data.html;
          version = data.version;

          const availableScroll =
            document.documentElement.scrollHeight - innerHeight;

          scrollTo(0, scrollRatio * Math.max(0, availableScroll));
        }

        document.getElementById("status").textContent = "Live Preview";
      } catch (_) {
        document.getElementById("status").textContent = "Disconnected";
      } finally {
        pending = false;
      }
    }

    refresh();
    setInterval(refresh, %d);
  </script>
</body>
</html>
]=], config.poll_ms)
end

local function response(client, code, content_type, body)
  if not client or client:is_closing() then
    return
  end

  local header = table.concat({
    "HTTP/1.1 " .. code,
    "Content-Type: " .. content_type,
    "Content-Length: " .. #body,
    "Cache-Control: no-store",
    "X-Content-Type-Options: nosniff",
    "Connection: close",
    "",
    "",
  }, "\r\n")

  client:write(header .. body, function()
    client:shutdown(function()
      state.clients[client] = nil
      close_handle(client)
    end)
  end)
end

local function handle_request(client, request)
  local method, path = request:match("^(%u+)%s+([^%s]+)")

  if method ~= "GET" then
    return response(client, "405 Method Not Allowed", "text/plain", "Method not allowed")
  end

  if path == "/" then
    return response(client, "200 OK", "text/html; charset=utf-8", browser_html())
  end

  if path == "/content" then
    local payload = vim.json.encode({
      html = state.html,
      version = state.version,
    })

    return response(client, "200 OK", "application/json; charset=utf-8", payload)
  end

  return response(client, "404 Not Found", "text/plain", "Not found")
end

local function render()
  if not state.active or not vim.api.nvim_buf_is_valid(state.buffer) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(state.buffer, 0, -1, false)
  local markdown = table.concat(lines, "\n")

  state.generation = state.generation + 1
  local generation = state.generation

  vim.system({
    "pandoc",
    "--from=markdown-raw_html",
    "--to=html",
    "--wrap=none",
  }, {
    stdin = markdown,
    text = true,
  }, function(result)
    vim.schedule(function()
      -- Discard results from older render operations.
      if not state.active or generation ~= state.generation then
        return
      end

      if result.code ~= 0 then
        notify(result.stderr or "Pandoc failed", vim.log.levels.ERROR)
        return
      end

      state.html = result.stdout or ""
      state.version = state.version + 1
    end)
  end)
end

local function schedule_render()
  if not state.timer then
    return
  end

  state.timer:stop()

  state.timer:start(config.debounce_ms, 0, function()
    vim.schedule(render)
  end)
end

local function start_server()
  local server = assert(uv.new_tcp())

  local ok, err = server:bind("127.0.0.1", config.port)

  if not ok then
    close_handle(server)
    return nil, err
  end

  local listen_ok, listen_err = server:listen(128, function(accept_err)
    if accept_err then
      return
    end

    local client = uv.new_tcp()
    if not client then return end

    local accepted = server:accept(client)

    if not accepted then
      close_handle(client)
      return
    end

    state.clients[client] = true

    local received = false

    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        state.clients[client] = nil
        close_handle(client)
        return
      end

      if received then return end

      received = true
      client:read_stop()

      vim.schedule(function()
        if not state.active then
          state.clients[client] = nil
          close_handle(client)
          return
        end

        handle_request(client, chunk)
      end)
    end)
  end)

  if not listen_ok then
    close_handle(server)
    return nil, listen_err
  end

  state.server = server
  state.port = server:getsockname().port

  return true
end

function M.stop()
  if not state.active then return end

  state.active = false
  state.generation = state.generation + 1

  if state.group then
    pcall(vim.api.nvim_del_augroup_by_id, state.group)
    state.group = nil
  end

  if state.timer then
    state.timer:stop()
    close_handle(state.timer)
    state.timer = nil
  end

  for client in pairs(state.clients) do
    close_handle(client)
    state.clients[client] = nil
  end

  close_handle(state.server)

  state.server = nil
  state.buffer = nil
  state.port = nil
  state.html = ""

  notify("Preview stopped")
end

function M.start()
  local bufnr = vim.api.nvim_get_current_buf()

  if vim.bo[bufnr].filetype ~= "markdown" then
    notify("Current buffer is not Markdown", vim.log.levels.WARN)
    return
  end

  if vim.fn.executable("pandoc") ~= 1 then
    notify("Pandoc is required. Install it first.", vim.log.levels.ERROR)
    return
  end

  if state.active then
    M.stop()
  end

  state.buffer = bufnr
  state.version = 0
  state.active = true

  local ok, err = start_server()

  if not ok then
    state.active = false
    state.buffer = nil
    notify("Cannot start HTTP server: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  state.timer = assert(uv.new_timer())

  state.group = vim.api.nvim_create_augroup("MarkdownPreviewLive", {
    clear = true,
  })

  vim.api.nvim_create_autocmd({
    "TextChanged",
    "TextChangedI",
    "InsertLeave",
    "BufWritePost",
  }, {
    group = state.group,
    buffer = bufnr,
    callback = schedule_render,
  })

  vim.api.nvim_create_autocmd({ "BufWipeout" }, {
    group = state.group,
    buffer = bufnr,
    callback = M.stop,
  })

  render()

  local url = string.format("http://127.0.0.1:%d/", state.port)

  if config.open_browser then
    local opened, open_err = vim.ui.open(url)

    if not opened then
      notify("Cannot open browser: " .. tostring(open_err), vim.log.levels.WARN)
    end
  end

  notify("Preview: " .. url)
end

function M.toggle()
  if state.active then
    M.stop()
  else
    M.start()
  end
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  vim.api.nvim_create_user_command("MarkdownPreview", M.start, {
    desc = "Start Markdown browser preview",
    force = true,
  })

  vim.api.nvim_create_user_command("MarkdownPreviewStop", M.stop, {
    desc = "Stop Markdown browser preview",
    force = true,
  })

  vim.api.nvim_create_user_command("MarkdownPreviewToggle", M.toggle, {
    desc = "Toggle Markdown browser preview",
    force = true,
  })
end

return M
