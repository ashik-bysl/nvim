-- PostgreSQL (and CQL) formatter.
--
-- Pipeline: tokenize -> annotate (keyword case, unary operators, spacing hints)
--           -> build a tree of statements/groups -> lay out clause by clause.
--
-- The module is pure Lua (no editor state), so it can be unit-tested with
-- `nvim -l tests/dbfmt_spec.lua`.

local M = {}

---------------------------------------------------------------------------
-- Vocabulary
---------------------------------------------------------------------------

local function set(words)
  local t = {}
  for w in words:gmatch("%S+") do
    t[w] = true
  end
  return t
end

-- Words that are always upper-cased. Type names and function names are left
-- alone on purpose, as are non-reserved words that are commonly column names.
local KEYWORDS = set([[
  ADD ALL ALTER ANALYSE ANALYZE AND ANY ARRAY AS ASC ASYMMETRIC AUTHORIZATION
  BEGIN BETWEEN BOTH BY CASCADE CASE CAST CHECK COLLATE COLUMN COMMIT CONCURRENTLY
  CONFLICT CONSTRAINT CREATE CROSS CURRENT_DATE CURRENT_ROLE CURRENT_TIME
  CURRENT_TIMESTAMP CURRENT_USER DATABASE DEFAULT DEFERRABLE DELETE DESC DISTINCT DO
  DROP ELSE END EXCEPT EXISTS EXPLAIN EXTENSION FALSE FETCH FILTER FOLLOWING FOR
  FOREIGN FROM FULL FUNCTION GENERATED GRANT GROUP HAVING ILIKE IN INDEX INNER INSERT
  INTERSECT INTO IS ISNULL JOIN LANGUAGE LATERAL LEADING LEFT LIKE LIMIT MATERIALIZED
  NATURAL NOT NOTHING NOTNULL NOWAIT NULL NULLS OF OFFSET ON ONLY OR ORDER OUTER OVER
  OVERLAPS PARTITION PRECEDING PRIMARY RANGE RECURSIVE REFERENCES RENAME REPLACE
  RESTRICT RETURNING RETURNS REVOKE RIGHT ROLLBACK ROWS SCHEMA SELECT SEQUENCE SET
  SIMILAR SOME TABLE TABLESAMPLE TEMP TEMPORARY THEN TO TRAILING TRIGGER TRUE
  TRUNCATE UNBOUNDED UNION UNIQUE UNKNOWN UNLOGGED UPDATE USING VACUUM VALUES VIEW
  WHEN WHERE WINDOW WITH WITHIN WITHOUT
]])

-- Upper-cased only when they open a statement (they are common identifiers elsewhere).
local STATEMENT_KEYWORDS = set([[
  ABORT CALL CHECKPOINT CLOSE CLUSTER COMMENT COPY DEALLOCATE DECLARE DISCARD EXECUTE
  IMPORT LISTEN LOCK MERGE NOTIFY PREPARE REFRESH REINDEX RELEASE RESET SAVEPOINT SHOW
  START UNLISTEN
]])

local DIALECT_KEYWORDS = {
  postgres = {},
  cql = set("KEYSPACE KEYSPACES CLUSTERING ALLOW FILTERING BATCH APPLY TTL TIMESTAMP"),
}

-- Keywords that are followed by a space before "(" ("IN (", "AS (").
-- Any other keyword is treated as function-like ("LEFT(", "ARRAY(").
local SPACE_BEFORE_PAREN = set([[
  IN AS ON AND OR NOT WHERE SELECT FROM JOIN VALUES USING EXISTS ANY ALL SOME OVER
  FILTER UNION INTERSECT EXCEPT WHEN THEN ELSE CASE HAVING BY GROUP ORDER RETURNING
  SET LIKE ILIKE IS BETWEEN DISTINCT ONLY LATERAL DO CONFLICT TO WITH RECURSIVE LIMIT
  OFFSET OF CHECK UNIQUE KEY DEFAULT EXPLAIN VERBOSE
]])

-- "INSERT INTO t (a, b)": a relation name that precedes "(" gets a space.
local RELATION_KEYWORDS = set("INTO TABLE REFERENCES COPY USING")

-- Keywords after which "-" or "+" is a binary operator.
local OPERAND_KEYWORDS = set("NULL TRUE FALSE END CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP")

local SUBQUERY_START = set("SELECT WITH VALUES TABLE INSERT UPDATE DELETE")
local SET_OPERATORS = set("UNION INTERSECT EXCEPT")
local JOIN_WORDS = set("NATURAL INNER LEFT RIGHT FULL CROSS OUTER")
local CREATE_MODIFIERS = set("OR REPLACE GLOBAL LOCAL TEMP TEMPORARY UNLOGGED")
local LIST_CLAUSES = set("SELECT FROM SET GROUPBY ORDERBY RETURNING VALUES USING WINDOW")

-- Statements whose body is laid out as a flat run of tokens.
local PLAIN_STATEMENTS = set([[
  GRANT REVOKE ALTER DROP COMMENT COPY SET RESET SHOW BEGIN START COMMIT ROLLBACK
  SAVEPOINT RELEASE TRUNCATE VACUUM ANALYZE ANALYSE LOCK LISTEN NOTIFY UNLISTEN DO
  CALL DISCARD REINDEX CLUSTER REFRESH
]])

---------------------------------------------------------------------------
-- Tokenizer
---------------------------------------------------------------------------

local WORD = "^[%a_\128-\255][%w_$\128-\255]*"

-- Returns the index just after the closing quote, or nil if unterminated.
local function scan_quoted(src, i, quote, backslash)
  local pat = backslash and ("[\\" .. quote .. "]") or quote
  local j = i + 1
  while true do
    local a = src:find(pat, j)
    if not a then
      return nil
    end
    if src:sub(a, a) == "\\" then
      j = a + 2
    elseif src:sub(a + 1, a + 1) == quote then
      j = a + 2
    else
      return a + 1
    end
  end
end

local function tokenize(src)
  local toks, n, i = {}, #src, 1
  local nl = false

  local function push(t, text)
    toks[#toks + 1] = { t = t, s = text, nl = nl }
    nl = false
  end

  local function prev_is_operand()
    local p = toks[#toks]
    if not p then
      return false
    end
    return p.t == "word" or p.t == "qident" or p.t == "number" or (p.t == "punct" and (p.s == ")" or p.s == "]"))
  end

  while i <= n do
    local c = src:sub(i, i)
    local c2 = src:sub(i, i + 1)

    if c == "\n" then
      nl = true
      i = i + 1
    elseif c:find("%s") then
      i = i + 1
    elseif c2 == "--" then
      local e = src:find("\n", i, true) or (n + 1)
      push("lcomment", (src:sub(i, e - 1):gsub("%s+$", "")))
      i = e
    elseif c2 == "/*" then
      local depth, j = 1, i + 2
      while depth > 0 do
        local a = src:find("[/*]", j)
        if not a then
          return nil, "unterminated block comment"
        end
        local two = src:sub(a, a + 1)
        if two == "/*" then
          depth, j = depth + 1, a + 2
        elseif two == "*/" then
          depth, j = depth - 1, a + 2
        else
          j = a + 1
        end
      end
      push("bcomment", src:sub(i, j - 1))
      i = j
    elseif c == "\\" and (i == 1 or src:sub(1, i - 1):find("\n[ \t]*$") or src:sub(1, i - 1):find("^%s*$")) then
      -- psql meta-command ("\d users"): keep the whole line verbatim.
      local e = src:find("\n", i, true) or (n + 1)
      push("raw", (src:sub(i, e - 1):gsub("%s+$", "")))
      i = e
    elseif
      c == "'"
      or (
        c:find("[eEbBxXnN]")
        and src:sub(i + 1, i + 1) == "'"
        and (i == 1 or not src:sub(i - 1, i - 1):find("[%w_$]"))
      )
    then
      local q = (c == "'") and i or (i + 1)
      local backslash = c == "e" or c == "E"
      local e = scan_quoted(src, q, "'", backslash)
      if not e then
        return nil, "unterminated string literal"
      end
      push("string", src:sub(i, e - 1))
      i = e
    elseif c == '"' then
      local e = scan_quoted(src, i, '"', false)
      if not e then
        return nil, "unterminated quoted identifier"
      end
      push("qident", src:sub(i, e - 1))
      i = e
    elseif c == "$" and src:find("^%$%d+", i) then
      local p = src:match("^%$%d+", i)
      push("param", p)
      i = i + #p
    elseif c == "$" and (src:find("^%$[%a_\128-\255][%w_\128-\255]*%$", i) or c2 == "$$") then
      local tag = src:match("^%$([%a_\128-\255][%w_\128-\255]*)%$", i) or ""
      local open = "$" .. tag .. "$"
      local close = src:find(open, i + #open, true)
      if not close then
        return nil, "unterminated dollar-quoted string"
      end
      push("string", src:sub(i, close + #open - 1))
      i = close + #open
    elseif c:find("%d") or (c == "." and src:find("^%.%d", i) and not prev_is_operand()) then
      local num = src:match("^0[xX]%x+", i)
      if not num then
        num = src:match("^%d*%.?%d*", i)
        if num:sub(-1) == "." then
          num = num:sub(1, -2)
        end
        local exp = src:match("^[eE][+-]?%d+", i + #num)
        if exp then
          num = num .. exp
        end
      end
      push("number", num)
      i = i + #num
    elseif c:find("[%a_\128-\255]") then
      local w = src:match(WORD, i)
      push("word", w)
      i = i + #w
    elseif c == "%" and (src:find("^%%%(%w+%)[sd]", i) or src:find("^%%[sd]%f[^%w_]", i)) then
      -- psycopg style placeholders: %s, %d, %(name)s
      local p = src:match("^%%%(%w+%)[sd]", i) or src:match("^%%[sd]", i)
      push("param", p)
      i = i + #p
    elseif c2 == "::" then
      push("punct", "::")
      i = i + 2
    elseif c2 == ":=" then
      push("op", ":=")
      i = i + 2
    elseif c == ":" and src:find("^:[%a_]", i) and not prev_is_operand() then
      -- psql variable (:name)
      local p = src:match("^:[%w_]+", i)
      push("param", p)
      i = i + #p
    elseif c == ":" then
      push("punct", ":")
      i = i + 1
    elseif c:find("[%(%)%[%],;%.]") then
      push("punct", c)
      i = i + 1
    elseif c:find("[%+%-%*/<>=~!@#%%%^&|%?]") then
      local op = src:match("^[%+%-%*/<>=~!@#%%%^&|%?]+", i)
      local cut = op:find("%-%-") or op:find("/%*")
      if cut then
        op = op:sub(1, cut - 1)
      end
      while #op > 1 and op:find("[%+%-]$") and not op:find("[~!@#%%%^&|%?]") do
        op = op:sub(1, -2)
      end
      push("op", op)
      i = i + #op
    else
      push("op", c)
      i = i + 1
    end
  end

  return toks
end

---------------------------------------------------------------------------
-- Annotation: keyword casing, unary operators, "(" spacing
---------------------------------------------------------------------------

local function is_comment(tk)
  return tk.t == "lcomment" or tk.t == "bcomment"
end

local function annotate(toks, opts)
  local extra = DIALECT_KEYWORDS[opts.dialect] or {}
  local S = {} -- significant (non-comment) tokens

  for _, tk in ipairs(toks) do
    if tk.t == "word" then
      tk.up = tk.s:upper()
      tk.kw = KEYWORDS[tk.up] or extra[tk.up] or false
    end
    if not is_comment(tk) then
      S[#S + 1] = tk
    end
  end

  -- Context-dependent keywords.
  for j, tk in ipairs(S) do
    if tk.t == "word" and not tk.kw then
      local p, nx, p2 = S[j - 1], S[j + 1], S[j - 2]
      local pu = p and p.t == "word" and p.up
      local nu = nx and nx.t == "word" and nx.up
      local p2u = p2 and p2.t == "word" and p2.up
      local u = tk.up
      if u == "KEY" and (pu == "PRIMARY" or pu == "FOREIGN") then
        tk.kw = true
      elseif (u == "FIRST" or u == "LAST") and pu == "NULLS" then
        tk.kw = true
      elseif u == "ALWAYS" and pu == "GENERATED" then
        tk.kw = true
      elseif u == "IDENTITY" and pu == "AS" then
        tk.kw = true
      elseif u == "IF" and (nu == "NOT" or nu == "EXISTS") then
        tk.kw = true
      elseif u == "ZONE" and pu == "TIME" and (p2u == "AT" or p2u == "WITH" or p2u == "WITHOUT") then
        tk.kw = true
      elseif u == "TIME" and nu == "ZONE" and (pu == "AT" or pu == "WITH" or pu == "WITHOUT") then
        tk.kw = true
      elseif (u == "SKIP" and nu == "LOCKED") or (u == "LOCKED" and pu == "SKIP") then
        tk.kw = true
      elseif u == "FIRST" and pu == "FETCH" or u == "NEXT" and pu == "FETCH" then
        tk.kw = true
      elseif u == "ROW" and (pu == "FIRST" or pu == "NEXT" or pu == "CURRENT") then
        tk.kw = true
      elseif u == "CURRENT" and nu == "ROW" and (pu == "BETWEEN" or pu == "AND") then
        tk.kw = true
      elseif u == "ESCAPE" and p and p.t == "string" then
        tk.kw = true
      elseif (u == "TABLES" or u == "SEQUENCES" or u == "FUNCTIONS" or u == "ROUTINES") and pu == "ALL" then
        tk.kw = true
      elseif u == "AT" and nu == "TIME" and S[j + 2] and S[j + 2].t == "word" and S[j + 2].up == "ZONE" then
        tk.kw = true
      end
    end
  end

  local stmt_first
  for j, tk in ipairs(S) do
    if tk.t == "punct" and tk.s == ";" then
      stmt_first = nil
    elseif tk.t == "word" and not stmt_first then
      stmt_first = tk.up
      if STATEMENT_KEYWORDS[tk.up] then
        tk.kw = true
      end
    end
    tk.stmt_first = stmt_first

    if tk.t == "word" then
      if tk.kw and opts.keyword_case == "upper" then
        tk.out = tk.up
      elseif tk.kw and opts.keyword_case == "lower" then
        tk.out = tk.s:lower()
      end
    end

    local p = S[j - 1]

    if tk.t == "op" and (tk.s == "-" or tk.s == "+" or tk.s == "~" or tk.s == "@") then
      tk.unary = p == nil
        or p.t == "op"
        or (p.t == "punct" and (p.s == "(" or p.s == "[" or p.s == ","))
        or (p.t == "word" and p.kw and not OPERAND_KEYWORDS[p.up])
    end

    if tk.t == "punct" and tk.s == "(" then
      local sp = false
      if p then
        if p.t == "word" and p.kw then
          sp = SPACE_BEFORE_PAREN[p.up] or false
        elseif p.t == "word" or p.t == "qident" then
          -- Walk back over a dotted name (schema.table) and look at what
          -- introduces it.
          local k = j - 1
          while
            S[k - 1]
            and S[k - 1].t == "punct"
            and S[k - 1].s == "."
            and S[k - 2]
            and (S[k - 2].t == "word" or S[k - 2].t == "qident")
          do
            k = k - 2
          end
          local before = S[k - 1]
          if before and before.t == "word" then
            if RELATION_KEYWORDS[before.up] then
              sp = true
            elseif before.up == "EXISTS" and S[k - 2] and S[k - 2].t == "word" and S[k - 2].up == "NOT" then
              sp = true
            elseif before.up == "ON" and tk.stmt_first == "CREATE" then
              sp = true
            end
          end
        elseif p.t == "punct" then
          sp = p.s == ")" or p.s == ","
        else
          sp = true -- after an operator, string, number or parameter
        end
      end
      tk.space_before = sp
    end
  end
end

---------------------------------------------------------------------------
-- Tree
---------------------------------------------------------------------------

local function finalize(node)
  local first
  for _, c in ipairs(node.children) do
    if not is_comment(c) then
      first = c
      break
    end
  end

  node.has_sub = false
  for _, c in ipairs(node.children) do
    if (c.t == "group" or c.t == "case") and (c.sub or c.has_sub) then
      node.has_sub = true
      break
    end
  end

  if node.t == "group" and node.kind == "[" then
    for _, c in ipairs(node.children) do
      if c.t == "punct" and c.s == ":" then
        c.slice = true
      end
    end
  end

  if node.t == "group" and node.kind == "(" and first then
    if first.t == "word" and SUBQUERY_START[first.up] then
      node.sub = true
    elseif first.t == "group" and first.sub then
      for _, c in ipairs(node.children) do
        if c.t == "word" and SET_OPERATORS[c.up] then
          node.sub = true
        end
      end
    end
  end
end

-- Replace an unterminated CASE with its tokens (e.g. plpgsql "END CASE").
local function flatten_case(parent_children, node)
  parent_children[#parent_children] = nil
  parent_children[#parent_children + 1] = node.open
  for _, c in ipairs(node.children) do
    parent_children[#parent_children + 1] = c
  end
end

local function build(toks)
  local stmts = {}
  local cur = { nodes = {} }
  local stack = {}
  local just_semi = false

  local function children()
    return #stack > 0 and stack[#stack].children or cur.nodes
  end

  local function all_case()
    for _, s in ipairs(stack) do
      if s.t ~= "case" then
        return false
      end
    end
    return true
  end

  local function unwind_cases()
    while #stack > 0 do
      local node = table.remove(stack)
      flatten_case(children(), node)
    end
  end

  for _, tk in ipairs(toks) do
    local top = stack[#stack]
    if just_semi and tk.t == "lcomment" and not tk.nl then
      stmts[#stmts].trail = tk
      just_semi = false
    else
      just_semi = false
      if tk.t == "punct" and (tk.s == "(" or tk.s == "[") then
        local g = { t = "group", kind = tk.s, open = tk, children = {} }
        table.insert(children(), g)
        stack[#stack + 1] = g
      elseif tk.t == "punct" and (tk.s == ")" or tk.s == "]") then
        local want = tk.s == ")" and "(" or "["
        -- Close CASE nodes that never saw their END.
        while #stack > 0 and stack[#stack].t == "case" do
          local node = table.remove(stack)
          flatten_case(children(), node)
        end
        top = stack[#stack]
        if top and top.kind == want then
          table.remove(stack)
          top.close = tk
          finalize(top)
        else
          return nil, "unbalanced '" .. tk.s .. "'"
        end
      elseif tk.t == "word" and tk.up == "CASE" then
        local c = { t = "case", open = tk, children = {} }
        table.insert(children(), c)
        stack[#stack + 1] = c
      elseif tk.t == "word" and tk.up == "END" and top and top.t == "case" then
        table.remove(stack)
        top.close = tk
        finalize(top)
      elseif tk.t == "punct" and tk.s == ";" and (#stack == 0 or all_case()) then
        unwind_cases()
        cur.semi = true
        stmts[#stmts + 1] = cur
        cur = { nodes = {} }
        just_semi = true
      elseif tk.t == "raw" and (#stack == 0 or all_case()) then
        unwind_cases()
        if #cur.nodes > 0 then
          stmts[#stmts + 1] = cur
        end
        stmts[#stmts + 1] = { nodes = { tk } }
        cur = { nodes = {} }
      else
        table.insert(children(), tk)
      end
    end
  end

  if not all_case() then
    return nil, "unbalanced '" .. stack[#stack].kind .. "'"
  end
  unwind_cases()
  if #cur.nodes > 0 then
    stmts[#stmts + 1] = cur
  end
  return stmts
end

---------------------------------------------------------------------------
-- Spacing and flat rendering
---------------------------------------------------------------------------

local NOSPACE_BEFORE =
  { [","] = true, [";"] = true, [")"] = true, ["]"] = true, ["."] = true, ["::"] = true, [":"] = true }
local NOSPACE_AFTER = { ["("] = true, ["["] = true, ["."] = true, ["::"] = true }

local function need_space(prev, cur)
  if not prev then
    return false
  end
  if cur.t == "punct" and NOSPACE_BEFORE[cur.s] then
    return false
  end
  if prev.t == "punct" and NOSPACE_AFTER[prev.s] then
    return false
  end
  if prev.t == "punct" and prev.s == ":" and prev.slice then
    return false -- a[1:2]; but a map entry reads  'key': value
  end
  if prev.unary then
    return false
  end
  if cur.t == "punct" and cur.s == "(" then
    return cur.space_before or false
  end
  if cur.t == "punct" and cur.s == "[" then
    return not (prev.t == "word" or prev.t == "qident" or (prev.t == "punct" and (prev.s == ")" or prev.s == "]")))
  end
  return true
end

-- Render nodes on one line. A line comment forces a "\n" so callers can tell
-- the result is not a single line.
local function flat(nodes)
  local out, prev = {}, nil

  local function add(tk)
    if prev and need_space(prev, tk) then
      out[#out + 1] = " "
    end
    out[#out + 1] = tk.out or tk.s
    prev = tk
  end

  local function walk(list)
    for _, nd in ipairs(list) do
      if nd.t == "group" or nd.t == "case" then
        add(nd.open)
        walk(nd.children)
        add(nd.close)
      else
        add(nd)
        if nd.t == "lcomment" then
          out[#out + 1] = "\n"
          prev = nil
        end
      end
    end
  end

  walk(nodes)
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Line builder
---------------------------------------------------------------------------

local Builder = {}
Builder.__index = Builder

local function new_builder(cfg)
  return setmetatable({
    cfg = cfg,
    lines = {},
    cur = "",
    cur_indent = 0,
    started = false,
    pending = false,
    pending_indent = 0,
    prev = nil,
  }, Builder)
end

function Builder:flush()
  if self.started then
    self.lines[#self.lines + 1] = string.rep(" ", self.cur_indent * self.cfg.indent) .. self.cur
  end
  self.cur = ""
  self.started = false
end

-- Request a line break before the next token. Takes effect lazily so that a
-- later request can override the indent and trailing comments can still be
-- attached to the previous line.
function Builder:nl(indent)
  if self.started or self.pending then
    self.pending = true
    self.pending_indent = indent
  end
end

function Builder:put(text, space)
  if self.pending then
    self:flush()
    self.cur_indent = self.pending_indent
    self.pending = false
    self.started = true
    self.cur = text
  elseif not self.started then
    self.started = true
    self.cur = text
  else
    self.cur = self.cur .. (space and " " or "") .. text
  end
end

function Builder:line_indent()
  return self.pending and self.pending_indent or self.cur_indent
end

function Builder:col()
  if self.pending or not self.started then
    return self:line_indent() * self.cfg.indent
  end
  local last = self.cur:match("[^\n]*$")
  if last ~= self.cur then
    return #last
  end
  return self.cur_indent * self.cfg.indent + #self.cur
end

local function emit_tok(B, tk)
  B:put(tk.out or tk.s, need_space(B.prev, tk))
  B.prev = tk
end

local function emit_comment(B, tk)
  if tk.t == "lcomment" then
    if tk.nl and B.started and not B.pending then
      B:nl(B:line_indent())
    end
    if not tk.nl and B.started and B.pending then
      B.cur = B.cur .. "  " .. tk.s
    else
      B:put(tk.s, true)
    end
    B:nl(B:line_indent())
  else
    if tk.nl and B.started and not B.pending then
      B:nl(B:line_indent())
    end
    B:put(tk.s, true)
  end
  B.prev = tk
end

---------------------------------------------------------------------------
-- Groups, CASE
---------------------------------------------------------------------------

local emit_seq

local function split_items(children)
  local items, item = {}, {}
  for _, c in ipairs(children) do
    if c.t == "punct" and c.s == "," then
      items[#items + 1] = item
      item = {}
    else
      item[#item + 1] = c
    end
  end
  items[#items + 1] = item

  local nonempty = {}
  for _, it in ipairs(items) do
    if #it > 0 then
      nonempty[#nonempty + 1] = it
    end
  end
  if #nonempty >= 2 then
    return nonempty, "comma"
  end

  -- No commas: try to split a long condition on AND / OR.
  local logic, current, between = {}, {}, false
  for _, c in ipairs(children) do
    if c.t == "word" and c.up == "BETWEEN" then
      between = true
    end
    if c.t == "word" and (c.up == "AND" or c.up == "OR") and #current > 0 then
      if c.up == "AND" and between then
        between = false
        current[#current + 1] = c
      else
        logic[#logic + 1] = current
        current = { c }
      end
    else
      current[#current + 1] = c
    end
  end
  logic[#logic + 1] = current
  if #logic >= 2 then
    return logic, "logic"
  end

  -- OVER (PARTITION BY ... ORDER BY ... ROWS ...): one clause per line.
  local parts, part = {}, {}
  for _, c in ipairs(children) do
    if
      c.t == "word"
      and (c.up == "PARTITION" or c.up == "ORDER" or c.up == "ROWS" or c.up == "RANGE" or c.up == "GROUPS")
      and #part > 0
    then
      parts[#parts + 1] = part
      part = { c }
    else
      part[#part + 1] = c
    end
  end
  parts[#parts + 1] = part
  if #parts >= 2 then
    return parts, "logic"
  end
  return nonempty, "comma"
end

local function has_line_comment(nodes)
  for _, c in ipairs(nodes) do
    if c.t == "lcomment" then
      return true
    end
  end
  return false
end

local function emit_nodes(B, nodes, ctx)
  for _, nd in ipairs(nodes) do
    ctx.emit_node(B, nd, ctx)
  end
end

local function fits(B, text, extra)
  return not text:find("\n") and B:col() + #text + (extra or 0) + 1 <= B.cfg.line_width
end

local function emit_sub(B, g, ctx)
  B:put("(", g.open.space_before and need_space(B.prev, g.open))
  B.prev = g.open
  local ind = B.cur_indent
  B:nl(ind + 1)
  emit_seq(B, g.children, ind + 1, ctx)
  B:nl(ind)
  B:put(")", false)
  B.prev = g.close
end

local function emit_group(B, g, ctx)
  if g.sub then
    return emit_sub(B, g, ctx)
  end

  local sp = need_space(B.prev, g.open)
  local text = (not g.has_sub) and flat({ g }) or nil
  if text and not g.force and fits(B, text, sp and 1 or 0) then
    B:put(text, sp)
    B.prev = g.close
    return
  end

  local items, mode = split_items(g.children)
  local broken = g.force or #items >= 2 or has_line_comment(g.children)

  B:put(g.open.s, sp)
  B.prev = g.open
  if not broken then
    emit_nodes(B, g.children, ctx)
    B:put(g.close.s, false)
    B.prev = g.close
    return
  end

  local ind = B.cur_indent
  for k, item in ipairs(items) do
    B:nl(ind + 1)
    emit_nodes(B, item, ctx)
    if mode == "comma" and k < #items then
      B:put(",", false)
      B.prev = { t = "punct", s = "," }
    end
  end
  B:nl(ind)
  B:put(g.close.s, false)
  B.prev = g.close
end

local function emit_case(B, c, ctx)
  local whens = 0
  for _, ch in ipairs(c.children) do
    if ch.t == "word" and ch.up == "WHEN" then
      whens = whens + 1
    end
  end

  local sp = need_space(B.prev, c.open)
  local text = (not c.has_sub) and whens <= 1 and flat({ c }) or nil
  if text and fits(B, text, sp and 1 or 0) then
    B:put(text, sp)
    B.prev = c.close
    return
  end

  B:put(c.open.out or c.open.s, sp)
  B.prev = c.open
  local ind = B.cur_indent
  for _, ch in ipairs(c.children) do
    if ch.t == "word" and (ch.up == "WHEN" or ch.up == "ELSE") then
      B:nl(ind + 1)
    end
    ctx.emit_node(B, ch, ctx)
  end
  B:nl(ind)
  B:put(c.close.out or c.close.s, false)
  B.prev = c.close
end

local function emit_node(B, nd, ctx)
  if nd.t == "group" then
    emit_group(B, nd, ctx)
  elseif nd.t == "case" then
    emit_case(B, nd, ctx)
  elseif is_comment(nd) then
    emit_comment(B, nd)
  else
    emit_tok(B, nd)
  end
end

---------------------------------------------------------------------------
-- Statement layout
---------------------------------------------------------------------------

emit_seq = function(B, nodes, base, ctx)
  local n = #nodes
  local st = {
    clause = nil,
    join = false,
    on = false,
    between = false,
    upd = false,
    nsig = 0,
    dml = false,
    tbl_done = false,
  }
  local prevsig = nil

  local head = {}
  for _, nd in ipairs(nodes) do
    if not is_comment(nd) then
      head[#head + 1] = nd
      if #head >= 8 then
        break
      end
    end
  end
  local first = head[1] and head[1].t == "word" and head[1].up or nil
  local plain = first ~= nil and PLAIN_STATEMENTS[first] or false
  local create_table = false
  if first == "CREATE" then
    for k = 2, #head do
      local h = head[k]
      if h.t ~= "word" then
        break
      end
      if h.up == "TABLE" then
        create_table = true
        break
      end
      if not CREATE_MODIFIERS[h.up] then
        break
      end
    end
  end

  local function wordat(j)
    local x = nodes[j]
    if x and x.t == "word" then
      return x.up
    end
  end

  local function tok(nd)
    emit_tok(B, nd)
    st.nsig = st.nsig + 1
    prevsig = nd
  end

  local function reset_clause_state()
    st.join, st.on, st.between = false, false, false
  end

  -- Returns kind, number of words, clause name.
  local function classify(i, nd)
    if plain then
      return nil
    end
    local u = nd.up
    local pw = prevsig and prevsig.t == "word" and prevsig.up or nil
    local n1, n2 = wordat(i + 1), wordat(i + 2)
    local stmt_start = st.nsig == 0 or (st.clause == "WITH" and prevsig and prevsig.t == "group")

    if u == "WITH" and st.nsig == 0 then
      return "with", (n1 == "RECURSIVE") and 2 or 1, "WITH"
    end
    if u == "SELECT" and pw ~= "FOR" then
      return "block", 1, "SELECT"
    end
    if u == "INSERT" and n1 == "INTO" and stmt_start then
      return "inline", 2, "INSERT INTO"
    end
    if u == "DELETE" and n1 == "FROM" and stmt_start then
      return "inline", 2, "DELETE FROM"
    end
    if u == "UPDATE" and stmt_start then
      return "inline", 1, "UPDATE"
    end
    if u == "VALUES" and pw ~= "DEFAULT" then
      return "block", 1, "VALUES"
    end

    if SET_OPERATORS[u] and prevsig and prevsig.t == "group" and prevsig.sub then
      return "setop", 1, u
    end

    if st.dml then
      if u == "FROM" and pw ~= "DISTINCT" then
        return "block", 1, "FROM"
      elseif u == "WHERE" then
        return "block", 1, "WHERE"
      elseif u == "HAVING" then
        return "block", 1, "HAVING"
      elseif u == "WINDOW" then
        return "block", 1, "WINDOW"
      elseif u == "RETURNING" then
        return "block", 1, "RETURNING"
      elseif (u == "GROUP" or u == "ORDER") and n1 == "BY" then
        return "block", 2, u .. "BY"
      elseif u == "SET" and st.upd then
        return "block", 1, "SET"
      elseif u == "USING" and not st.join and st.clause == "DELETE FROM" then
        return "block", 1, "USING"
      elseif u == "LIMIT" or u == "OFFSET" or u == "FETCH" then
        return "inline", 1, u
      elseif u == "ON" and n1 == "CONFLICT" then
        return "inline", 2, "ON CONFLICT"
      elseif u == "DO" and (n1 == "UPDATE" or n1 == "NOTHING") then
        return "inline", 2, "DO " .. n1
      elseif u == "FOR" and (n1 == "UPDATE" or n1 == "SHARE" or n1 == "NO" or n1 == "KEY") then
        return "inline", 2, "FOR"
      elseif SET_OPERATORS[u] then
        return "setop", 1, u
      elseif JOIN_WORDS[u] or u == "JOIN" then
        local j = i
        while wordat(j) and JOIN_WORDS[wordat(j)] do
          j = j + 1
        end
        if wordat(j) == "JOIN" then
          return "join", j - i + 1, "JOIN"
        end
      end
    end
    return nil
  end

  local i = 1
  while i <= n do
    local nd = nodes[i]

    if is_comment(nd) then
      emit_comment(B, nd)
      i = i + 1
    elseif nd.t == "word" then
      local u = nd.up
      local kind, count, name = classify(i, nd)

      if u == "EXPLAIN" and st.nsig == 0 then
        tok(nd)
        i = i + 1
        while wordat(i) == "ANALYZE" or wordat(i) == "ANALYSE" or wordat(i) == "VERBOSE" do
          emit_tok(B, nodes[i])
          i = i + 1
        end
        if nodes[i] and nodes[i].t == "group" then
          emit_group(B, nodes[i], ctx)
          i = i + 1
        end
        st.nsig = 0
        prevsig = nil
      elseif kind == "with" then
        B:nl(base)
        for k = 0, count - 1 do
          tok(nodes[i + k])
        end
        st.clause, st.dml = "WITH", true
        i = i + count
      elseif kind == "block" then
        B:nl(base)
        for k = 0, count - 1 do
          tok(nodes[i + k])
        end
        i = i + count
        st.clause, st.dml = name, true
        reset_clause_state()
        if name == "SELECT" then
          while wordat(i) == "DISTINCT" or wordat(i) == "ALL" do
            tok(nodes[i])
            i = i + 1
            if wordat(i) == "ON" and nodes[i + 1] and nodes[i + 1].t == "group" then
              tok(nodes[i])
              emit_group(B, nodes[i + 1], ctx)
              prevsig = nodes[i + 1]
              i = i + 2
            end
          end
        end
        B:nl(base + 1)
      elseif kind == "inline" then
        B:nl(base)
        for k = 0, count - 1 do
          tok(nodes[i + k])
        end
        i = i + count
        st.clause, st.dml = name, true
        if name == "UPDATE" or name == "DO UPDATE" then
          st.upd = true
        end
        reset_clause_state()
      elseif kind == "setop" then
        B:nl(base)
        tok(nd)
        i = i + 1
        if wordat(i) == "ALL" or wordat(i) == "DISTINCT" then
          tok(nodes[i])
          i = i + 1
        end
        B:nl(base)
        st.clause, st.upd = nil, false
        reset_clause_state()
      elseif kind == "join" then
        B:nl(base + 1)
        for k = 0, count - 1 do
          tok(nodes[i + k])
        end
        i = i + count
        st.join, st.on, st.between = true, false, false
      else
        if u == "ON" and st.join then
          st.join, st.on = false, true
          tok(nd)
        elseif u == "USING" and st.join then
          st.join = false
          tok(nd)
        elseif (u == "AND" or u == "OR") and (st.clause == "WHERE" or st.clause == "HAVING" or st.on) then
          if u == "AND" and st.between then
            st.between = false
          else
            B:nl(st.on and base + 2 or base + 1)
          end
          tok(nd)
        else
          if u == "BETWEEN" then
            st.between = true
          end
          tok(nd)
        end
        i = i + 1
      end
    elseif nd.t == "punct" and nd.s == "," then
      tok(nd)
      if st.clause == "WITH" then
        B:nl(base)
      elseif st.clause and LIST_CLAUSES[st.clause] then
        B:nl(base + 1)
        reset_clause_state()
      end
      i = i + 1
    elseif nd.t == "group" then
      if
        create_table
        and not st.tbl_done
        and not nd.sub
        and nd.kind == "("
        and prevsig
        and ((prevsig.t == "word" and not prevsig.kw) or prevsig.t == "qident")
      then
        nd.force = true
        st.tbl_done = true
      end
      emit_group(B, nd, ctx)
      st.nsig = st.nsig + 1
      prevsig = nd
      i = i + 1
    elseif nd.t == "case" then
      emit_case(B, nd, ctx)
      st.nsig = st.nsig + 1
      prevsig = nd
      i = i + 1
    else
      tok(nd)
      i = i + 1
    end
  end
end

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

M.defaults = {
  dialect = "postgres",
  indent = 2,
  line_width = 80,
  keyword_case = "upper", -- "upper" | "lower" | "preserve"
  blank_lines = 1, -- blank lines between statements
}

---Format SQL text.
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
  annotate(toks, cfg)

  local stmts, berr = build(toks)
  if not stmts then
    return nil, berr
  end

  local ctx = { cfg = cfg, emit_node = emit_node }
  local out = {}
  for _, stmt in ipairs(stmts) do
    if #stmt.nodes > 0 then
      local B = new_builder(cfg)
      emit_seq(B, stmt.nodes, 0, ctx)
      if stmt.semi then
        if B.pending then
          B:nl(0)
        end
        B:put(";", false)
      end
      if stmt.trail then
        B:put(stmt.trail.s, true)
      end
      B:flush()
      if #B.lines > 0 then
        if #out > 0 then
          for _ = 1, cfg.blank_lines do
            out[#out + 1] = ""
          end
        end
        for _, l in ipairs(B.lines) do
          out[#out + 1] = l
        end
      end
    end
  end

  return table.concat(out, "\n")
end

return M
