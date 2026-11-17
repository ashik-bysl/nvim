-- Redis command formatter: one command per line, command names upper-cased,
-- arguments (including quoted strings) untouched.

local M = {}

-- Commands whose first argument is a sub-command (CONFIG GET, CLIENT LIST ...).
local CONTAINER_COMMANDS = {}
for w in
  ([[ACL CLIENT CLUSTER COMMAND CONFIG DEBUG FUNCTION LATENCY MEMORY MODULE OBJECT PUBSUB
  SCRIPT SLOWLOG XGROUP XINFO]]):gmatch("%S+")
do
  CONTAINER_COMMANDS[w] = true
end

-- Split a line into arguments, honouring "double" and 'single' quotes.
local function split_args(line)
  local args, i, n = {}, 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c:find("%s") then
      i = i + 1
    else
      local j = i
      local quote
      while j <= n do
        local ch = line:sub(j, j)
        if quote then
          if ch == "\\" and quote == '"' then
            j = j + 1
          elseif ch == quote then
            quote = nil
          end
        elseif ch == '"' or ch == "'" then
          quote = ch
        elseif ch:find("%s") then
          break
        end
        j = j + 1
      end
      if quote then
        return nil
      end
      args[#args + 1] = line:sub(i, j - 1)
      i = j
    end
  end
  return args
end

---@param src string
---@param _ table|nil
---@return string|nil formatted
---@return string|nil err
function M.format(src, _)
  local out = {}
  local blank = false
  for _, raw in ipairs(vim.split(src, "\n", { plain = true })) do
    local line = vim.trim(raw)
    if line == "" then
      blank = #out > 0
    else
      if blank then
        out[#out + 1] = ""
        blank = false
      end
      if line:sub(1, 1) == "#" then
        out[#out + 1] = line
      else
        local args = split_args(line)
        if not args then
          return nil, "unterminated quote in: " .. line
        end
        args[1] = args[1]:upper()
        if CONTAINER_COMMANDS[args[1]] and args[2] and not args[2]:find("^[\"']") then
          args[2] = args[2]:upper()
        end
        out[#out + 1] = table.concat(args, " ")
      end
    end
  end
  return table.concat(out, "\n")
end

return M
