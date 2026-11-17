-- Document-store formatter: MongoDB shell scripts (mongosh), JSON / extended
-- JSON documents, aggregation pipelines and Elasticsearch-style query bodies.
--
-- It is a structural pretty-printer rather than a JavaScript parser: brackets,
-- braces and parentheses are laid out; everything else is spaced token by
-- token. Brace blocks that look like code (function bodies, anything with a
-- ";") are copied through untouched.

local M = {}

M.defaults = {
  indent = 2,
  line_width = 80,
  -- "compact":  objects/arrays stay on one line when they fit (mongosh style)
  -- "expanded": every non-empty object breaks, arrays of scalars stay inline (JSON style)
  style = "compact",
}

local function set(words)
  local t = {}
  for w in words:gmatch("%S+") do
    t[w] = true
  end
  return t
end

-- Words that expect an operand to follow them.
local PREFIX_WORDS =
  set("const let var return new typeof await async delete void throw in of else case yield instanceof")
local CONTROL_WORDS = set("if for while switch catch")
local REGEX_PRECEDING_WORDS = set("return typeof in of case void delete throw instanceof")
local NOT_A_STATEMENT_START = set("else catch finally")

---------------------------------------------------------------------------
-- Tokenizer
---------------------------------------------------------------------------

local function scan_string(src, i, quote)
  local j = i + 1
  while true do
    local a = src:find("[\\" .. quote .. "]", j)
    if not a then
      return nil
    end
    if src:sub(a, a) == "\\" then
      j = a + 2
    else
      return a + 1
    end
  end
end

local function is_comment(tk)
  return tk.t == "lcomment" or tk.t == "bcomment"
end

local function tokenize(src)
  local toks, n, i = {}, #src, 1
  local newlines = 0

  local function push(t, text, from)
    toks[#toks + 1] = {
      t = t,
      s = text,
      nl = newlines > 0,
      blank = newlines > 1,
      pos = from,
      epos = from + #text - 1,
    }
    newlines = 0
  end

  local function regex_allowed()
    local p
    for k = #toks, 1, -1 do
      if not is_comment(toks[k]) then
        p = toks[k]
        break
      end
    end
    if not p then
      return true
    end
    if p.t == "punct" then
      return p.s ~= ")" and p.s ~= "]" and p.s ~= "}"
    elseif p.t == "op" then
      return true
    elseif p.t == "word" then
      return REGEX_PRECEDING_WORDS[p.s] or false
    end
    return false
  end

  while i <= n do
    local c = src:sub(i, i)
    local c2 = src:sub(i, i + 1)

    if c == "\n" then
      newlines = newlines + 1
      i = i + 1
    elseif c:find("%s") then
      i = i + 1
    elseif c2 == "//" then
      local e = src:find("\n", i, true) or (n + 1)
      push("lcomment", (src:sub(i, e - 1):gsub("%s+$", "")), i)
      i = e
    elseif c2 == "/*" then
      local e = src:find("*/", i + 2, true)
      if not e then
        return nil, "unterminated block comment"
      end
      push("bcomment", src:sub(i, e + 1), i)
      i = e + 2
    elseif c == '"' or c == "'" or c == "`" then
      local e = scan_string(src, i, c)
      if not e then
        return nil, "unterminated string"
      end
      push("string", src:sub(i, e - 1), i)
      i = e
    elseif c == "/" and regex_allowed() then
      local j, in_class = i + 1, false
      while true do
        local ch = src:sub(j, j)
        if ch == "" or ch == "\n" then
          return nil, "unterminated regular expression"
        elseif ch == "\\" then
          j = j + 1
        elseif ch == "[" then
          in_class = true
        elseif ch == "]" then
          in_class = false
        elseif ch == "/" and not in_class then
          break
        end
        j = j + 1
      end
      local flags = src:match("^%a*", j + 1)
      push("regex", src:sub(i, j + #flags), i)
      i = j + #flags + 1
    elseif c:find("%d") or (c == "." and src:find("^%.%d", i)) then
      local num = src:match("^0[xX]%x+", i)
      if not num then
        num = src:match("^%d*%.?%d*", i)
        if num:sub(-1) == "." and not src:find("^%d", i + #num) then
          num = num:sub(1, -2)
        end
        local exp = src:match("^[eE][+-]?%d+", i + #num)
        if exp then
          num = num .. exp
        end
        if src:sub(i + #num, i + #num) == "n" then
          num = num .. "n"
        end
      end
      push("number", num, i)
      i = i + #num
    elseif c:find("[%a_$\128-\255]") then
      local w = src:match("^[%w_$\128-\255]+", i)
      push("word", w, i)
      i = i + #w
    elseif src:sub(i, i + 2) == "..." then
      push("op", "...", i)
      i = i + 3
    elseif c2 == "?." and not src:find("^%d", i + 2) then
      push("op", "?.", i)
      i = i + 2
    elseif c:find("[{}%[%]%(%):,;%.]") then
      push("punct", c, i)
      i = i + 1
    elseif c:find("[%+%-%*/%%<>=!&|%?%^~]") then
      local op = src:match("^[%+%-%*/%%<>=!&|%?%^~]+", i)
      local cut = op:find("//", 2, true) or op:find("/*", 2, true)
      if cut then
        op = op:sub(1, cut - 1)
      end
      push("op", op, i)
      i = i + #op
    else
      push("op", c, i)
      i = i + 1
    end
  end

  return toks
end

local function annotate(toks)
  local p
  for _, tk in ipairs(toks) do
    if not is_comment(tk) then
      if tk.t == "op" and (tk.s == "-" or tk.s == "+" or tk.s == "!" or tk.s == "~") then
        tk.unary = p == nil
          or p.t == "op"
          or (p.t == "punct" and (p.s == "(" or p.s == "[" or p.s == "," or p.s == ":" or p.s == "{" or p.s == ";"))
          or (p.t == "word" and PREFIX_WORDS[p.s] or false)
      end
      p = tk
    end
  end
end

---------------------------------------------------------------------------
-- Tree
---------------------------------------------------------------------------

local CLOSERS = { ["{"] = "}", ["["] = "]", ["("] = ")" }

-- Can a "{" at this position start an object literal (as opposed to a block)?
local function object_context(prev)
  if not prev then
    return true
  end
  if prev.t == "punct" then
    return prev.s == "(" or prev.s == "[" or prev.s == "," or prev.s == ":" or prev.s == "{"
  elseif prev.t == "op" then
    return prev.s ~= "=>"
  elseif prev.t == "word" then
    return prev.s == "return"
  end
  return false
end

local function build(toks, src)
  local root = { children = {} }
  local stack = { root }
  local prev_sig

  for _, tk in ipairs(toks) do
    local top = stack[#stack]
    if tk.t == "punct" and CLOSERS[tk.s] then
      local g = {
        t = "group",
        kind = tk.s,
        open = tk,
        children = {},
        nl = tk.nl,
        blank = tk.blank,
        -- A "{" that starts a new top-level line is an object (NDJSON, pasted
        -- documents); it is demoted to a code block below if it contains ";".
        obj = tk.s ~= "{" or object_context(prev_sig) or (top == root and tk.nl),
      }
      table.insert(top.children, g)
      stack[#stack + 1] = g
      prev_sig = tk
    elseif tk.t == "punct" and (tk.s == "}" or tk.s == "]" or tk.s == ")") then
      if #stack == 1 or CLOSERS[top.kind] ~= tk.s then
        return nil, "unbalanced '" .. tk.s .. "'"
      end
      table.remove(stack)
      top.close = tk
      for _, c in ipairs(top.children) do
        if c.t == "punct" and c.s == ";" then
          top.obj = false
        end
      end
      if top.kind == "{" and not top.obj then
        -- Code block: copy the source verbatim.
        local parent = stack[#stack]
        parent.children[#parent.children] = {
          t = "raw",
          s = src:sub(top.open.pos, tk.epos),
          nl = top.nl,
          blank = top.blank,
        }
      end
      prev_sig = tk
    else
      table.insert(top.children, tk)
      if not is_comment(tk) then
        prev_sig = tk
      end
    end
  end

  if #stack > 1 then
    return nil, "unbalanced '" .. stack[#stack].kind .. "'"
  end
  return root.children
end

---------------------------------------------------------------------------
-- Spacing and flat rendering
---------------------------------------------------------------------------

local NO_SPACE_BEFORE = { [","] = true, [";"] = true, [")"] = true, ["]"] = true, ["."] = true, [":"] = true }

local function need_space(prev, cur)
  if not prev then
    return false
  end
  if cur.t == "punct" and NO_SPACE_BEFORE[cur.s] then
    return false
  end
  if cur.t == "op" and cur.s == "?." then
    return false
  end
  if prev.t == "punct" and (prev.s == "(" or prev.s == "[" or prev.s == ".") then
    return false
  end
  if prev.t == "op" and (prev.s == "?." or prev.s == "...") then
    return false
  end
  if prev.unary then
    return false
  end
  if cur.t == "punct" and cur.s == "(" then
    if prev.t == "word" then
      return CONTROL_WORDS[prev.s] or false
    elseif prev.t == "punct" then
      return not (prev.s == ")" or prev.s == "]" or prev.s == "}")
    end
    return prev.t == "op"
  end
  if cur.t == "punct" and cur.s == "[" then
    if prev.t == "word" then
      return PREFIX_WORDS[prev.s] or false
    elseif prev.t == "punct" then
      return not (prev.s == ")" or prev.s == "]" or prev.s == "}")
    end
    return prev.t == "op"
  end
  return true
end

local function span_tokens(nd)
  if nd.t == "group" then
    return nd.open, nd.close
  end
  return nd, nd
end

local flat_nodes

local function flat_group(g)
  if g.t == "raw" then
    return g.s
  end
  local inner = flat_nodes(g.children)
  if g.kind == "{" then
    return inner == "" and "{}" or ("{ " .. inner .. " }")
  end
  return g.kind .. inner .. CLOSERS[g.kind]
end

flat_nodes = function(nodes)
  local out, prev = {}, nil
  for _, nd in ipairs(nodes) do
    local first, last = span_tokens(nd)
    if prev and need_space(prev, first) then
      out[#out + 1] = " "
    end
    if nd.t == "group" or nd.t == "raw" then
      out[#out + 1] = flat_group(nd)
    else
      out[#out + 1] = nd.s
      if nd.t == "lcomment" then
        out[#out + 1] = "\n"
        last = nil
      end
    end
    prev = last
  end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

local render_nodes

local function indent_str(cfg, level)
  return string.rep(" ", level * cfg.indent)
end

-- Split children on commas. Line comments that trail an entry are kept with
-- it so the comma can be placed before the comment.
local function split_items(children)
  local items = { { nodes = {} } }
  for _, c in ipairs(children) do
    local cur = items[#items]
    if c.t == "punct" and c.s == "," then
      items[#items + 1] = { nodes = {} }
    elseif #cur.nodes == 0 and c.t == "lcomment" and not c.nl and #items > 1 and not items[#items - 1].trail then
      items[#items - 1].trail = c
    else
      cur.nodes[#cur.nodes + 1] = c
    end
  end

  local result = {}
  for _, it in ipairs(items) do
    local last = it.nodes[#it.nodes]
    if last and last.t == "lcomment" and #it.nodes > 1 and not it.trail then
      it.trail = last
      it.nodes[#it.nodes] = nil
    end
    if #it.nodes > 0 then
      result[#result + 1] = it
    end
  end
  return result
end

local function all_scalar(g)
  for _, c in ipairs(g.children) do
    if c.t == "group" or c.t == "raw" or is_comment(c) then
      return false
    end
  end
  return true
end

local function render_group(g, ind, col, cfg)
  if g.t == "raw" then
    return g.s
  end

  local kind = g.kind
  if #g.children == 0 then
    return kind .. CLOSERS[kind]
  end

  local text = flat_group(g)
  local fit = not text:find("\n") and col + #text + 1 <= cfg.line_width
  local items = split_items(g.children)

  if kind == "{" then
    if cfg.style == "compact" and fit then
      return text
    end
  elseif kind == "[" then
    if fit and (cfg.style == "compact" or all_scalar(g)) then
      return text
    end
  else
    if fit then
      return text
    end
    -- f({ ... }) / f([ ... ]): hug the only argument.
    if #items == 1 and #items[1].nodes == 1 and items[1].nodes[1].t == "group" and not items[1].trail then
      return "(" .. render_group(items[1].nodes[1], ind, col + 1, cfg) .. ")"
    end
  end

  local lines = {}
  for k, item in ipairs(items) do
    local body = render_nodes(item.nodes, ind + 1, (ind + 1) * cfg.indent, cfg)
    local comma = k < #items and "," or ""
    local trail = item.trail and ("  " .. item.trail.s) or ""
    lines[#lines + 1] = indent_str(cfg, ind + 1) .. body .. comma .. trail
  end
  return kind .. "\n" .. table.concat(lines, "\n") .. "\n" .. indent_str(cfg, ind) .. CLOSERS[kind]
end

render_nodes = function(nodes, ind, col, cfg)
  -- db.a.find(...).sort(...).limit(...): break before each chained call when
  -- the whole expression does not fit.
  local breaks = {}
  local calls = {}
  for k, nd in ipairs(nodes) do
    local before, name, args = nodes[k - 1], nodes[k + 1], nodes[k + 2]
    if
      nd.t == "punct"
      and nd.s == "."
      and before
      and before.t == "group"
      and before.kind == "("
      and name
      and name.t == "word"
      and args
      and args.t == "group"
      and args.kind == "("
    then
      calls[#calls + 1] = k
    end
  end
  if #calls >= 2 then
    local text = flat_nodes(nodes)
    if text:find("\n") or col + #text > cfg.line_width then
      for _, k in ipairs(calls) do
        breaks[k] = true
      end
    end
  end

  local out = {}
  local curcol = col
  local cur_ind = ind
  local prev = nil
  local pending_break = false

  local function append(text, space)
    if pending_break then
      out[#out + 1] = "\n" .. indent_str(cfg, cur_ind)
      curcol = cur_ind * cfg.indent
      pending_break = false
    elseif space then
      out[#out + 1] = " "
      curcol = curcol + 1
    end
    out[#out + 1] = text
    local last = text:match("[^\n]*$")
    if last ~= text then
      curcol = #last
    else
      curcol = curcol + #text
    end
  end

  for k, nd in ipairs(nodes) do
    if breaks[k] then
      cur_ind = ind + 1
      pending_break = true
      append(".", false)
      prev = nd
    elseif nd.t == "group" or nd.t == "raw" then
      local first, last = span_tokens(nd)
      local space = need_space(prev, first)
      append(render_group(nd, cur_ind, curcol + (space and 1 or 0), cfg), space)
      prev = last
    elseif nd.t == "lcomment" then
      append(nd.s, prev ~= nil)
      pending_break = true
      prev = nil
    else
      append(nd.s, need_space(prev, nd))
      prev = nd
    end
  end

  return table.concat(out)
end

---------------------------------------------------------------------------
-- Statements
---------------------------------------------------------------------------

local function ends_expression(nd)
  if nd.t == "group" or nd.t == "raw" then
    return true
  end
  if nd.t == "word" then
    return not PREFIX_WORDS[nd.s]
  end
  return nd.t == "string" or nd.t == "number" or nd.t == "regex"
end

local function starts_expression(nd, prev)
  if nd.t == "group" then
    return nd.kind == "{" or (nd.kind == "[" and prev.t == "group" and prev.kind ~= "(")
  end
  if nd.t == "raw" then
    return true
  end
  if nd.t == "word" then
    return not NOT_A_STATEMENT_START[nd.s]
  end
  return nd.t == "string" or nd.t == "number" or nd.t == "regex"
end

local function split_statements(nodes)
  local stmts, cur = {}, {}

  local function flush()
    if #cur > 0 then
      stmts[#stmts + 1] = cur
      cur = {}
    end
  end

  for _, nd in ipairs(nodes) do
    local prev = cur[#cur]
    if is_comment(nd) then
      if nd.nl or #cur == 0 then
        flush()
        stmts[#stmts + 1] = { nd }
      else
        cur[#cur + 1] = nd
      end
    elseif nd.t == "punct" and nd.s == ";" then
      cur[#cur + 1] = nd
      flush()
    else
      if prev and nd.nl and not is_comment(prev) and ends_expression(prev) and starts_expression(nd, prev) then
        flush()
      end
      cur[#cur + 1] = nd
    end
  end
  flush()
  return stmts
end

---Format a document-store script or JSON document.
---@param src string
---@param opts? table
---@return string|nil formatted
---@return string|nil err
function M.format(src, opts)
  local cfg = vim.tbl_extend("force", M.defaults, opts or {})

  local toks, err = tokenize(src)
  if not toks then
    return nil, err
  end
  annotate(toks)

  local tree, berr = build(toks, src)
  if not tree then
    return nil, berr
  end

  local out = {}
  for _, stmt in ipairs(split_statements(tree)) do
    local first = stmt[1]
    if #out > 0 and first.blank then
      out[#out + 1] = ""
    end
    out[#out + 1] = render_nodes(stmt, 0, 0, cfg)
  end
  return table.concat(out, "\n")
end

return M
