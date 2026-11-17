-- Run with:  nvim -l tests/dbfmt_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local dbfmt = require("dbfmt")
dbfmt.setup({ indent = 2 }) -- headless nvim has shiftwidth=8
local failures, count = 0, 0

local function check(name, ok, detail)
  count = count + 1
  if not ok then
    failures = failures + 1
    print("FAIL: " .. name)
    if detail then
      print(detail)
    end
  end
end

local function eq(name, got, want)
  check(name, got == want, ("--- got\n%s\n--- want\n%s"):format(tostring(got), tostring(want)))
end

local function squash(s)
  return (s:gsub("%s+", ""))
end

---------------------------------------------------------------------------
-- SQL (PostgreSQL)
---------------------------------------------------------------------------

local sql_cases = {}
local function sql_case(name, input, want)
  sql_cases[#sql_cases + 1] = { name = name, input = input, want = want }
end

sql_case(
  "select / joins / where / group / order / limit",
  [[select u.id,u.name,count(*) as total from users u inner join orders o on o.user_id=u.id and o.status='paid' left join x using (id) where u.active=true and o.created_at> now()-interval '7 days' and u.id between 1 and 5 or u.x in (1,2,3) group by u.id,u.name having count(*)>1 order by total desc limit 10 offset 5;]],
  [[
SELECT
  u.id,
  u.name,
  count(*) AS total
FROM
  users u
  INNER JOIN orders o ON o.user_id = u.id
    AND o.status = 'paid'
  LEFT JOIN x USING (id)
WHERE
  u.active = TRUE
  AND o.created_at > now() - interval '7 days'
  AND u.id BETWEEN 1 AND 5
  OR u.x IN (1, 2, 3)
GROUP BY
  u.id,
  u.name
HAVING
  count(*) > 1
ORDER BY
  total DESC
LIMIT 10
OFFSET 5;]]
)

sql_case(
  "CTEs, subquery, CASE, union",
  [[with recent as (select * from events where ts > now() - interval '1 day'), agg as (select user_id, count(*) c from recent group by 1) select a.*, case when c > 10 then 'high' else 'low' end as bucket from agg a where a.user_id in (select id from users where deleted_at is null) union all select 1,2,'x';]],
  [[
WITH recent AS (
  SELECT
    *
  FROM
    events
  WHERE
    ts > now() - interval '1 day'
),
agg AS (
  SELECT
    user_id,
    count(*) c
  FROM
    recent
  GROUP BY
    1
)
SELECT
  a.*,
  CASE WHEN c > 10 THEN 'high' ELSE 'low' END AS bucket
FROM
  agg a
WHERE
  a.user_id IN (
    SELECT
      id
    FROM
      users
    WHERE
      deleted_at IS NULL
  )
UNION ALL
SELECT
  1,
  2,
  'x';]]
)

sql_case(
  "insert on conflict / update from / delete using",
  [[insert into public.users (id,name,meta) values (1,'a','{"k":1}'::jsonb),(2,'b',$1) on conflict (id) do update set name=excluded.name, meta = users.meta || excluded.meta returning id, name;
update t set a=1,b=b+1 from other o where o.id=t.id and t.x is distinct from o.x;
delete from t using u where t.id=u.id;]],
  [[
INSERT INTO public.users (id, name, meta)
VALUES
  (1, 'a', '{"k":1}'::jsonb),
  (2, 'b', $1)
ON CONFLICT (id)
DO UPDATE
SET
  name = excluded.name,
  meta = users.meta || excluded.meta
RETURNING
  id,
  name;

UPDATE t
SET
  a = 1,
  b = b + 1
FROM
  other o
WHERE
  o.id = t.id
  AND t.x IS DISTINCT FROM o.x;

DELETE FROM t
USING
  u
WHERE
  t.id = u.id;]]
)

sql_case(
  "DDL, dollar quoting",
  [[create table if not exists accounts (id bigserial primary key, email text not null unique, created_at timestamp with time zone default now(), org_id int references orgs(id) on delete cascade, check (length(email) > 3));
create index concurrently idx_a on accounts using gin (email) where id > 5;
create function f(a int) returns int as $$ begin return a+1; end $$ language plpgsql;]],
  [[
CREATE TABLE IF NOT EXISTS accounts (
  id bigserial PRIMARY KEY,
  email text NOT NULL UNIQUE,
  created_at timestamp WITH TIME ZONE DEFAULT now(),
  org_id int REFERENCES orgs (id) ON DELETE CASCADE,
  CHECK (length(email) > 3)
);

CREATE INDEX CONCURRENTLY idx_a ON accounts USING gin (email) WHERE id > 5;

CREATE FUNCTION f(a int) RETURNS int AS $$ begin return a+1; end $$ LANGUAGE plpgsql;]]
)

sql_case(
  "comments, JSON operators, casts, locking",
  [[-- leading comment
select a, -- first
  b /* inline */, c from t; -- trailing
-- second
select data->>'name', data#>'{a,b}', arr[1], -1, 'x'||'y' from j where x = ANY(ARRAY[1,2,3]) and y ilike '%a%' for update skip locked;]],
  [[
-- leading comment
SELECT
  a,  -- first
  b /* inline */,
  c
FROM
  t; -- trailing

-- second
SELECT
  data ->> 'name',
  data #> '{a,b}',
  arr[1],
  -1,
  'x' || 'y'
FROM
  j
WHERE
  x = ANY (ARRAY[1, 2, 3])
  AND y ILIKE '%a%'
FOR UPDATE SKIP LOCKED;]]
)

sql_case(
  "placeholders and parameters",
  [[select * from t where a = %s and b = %(name)s and c = :id and d = $2 and e = ?]],
  [[
SELECT
  *
FROM
  t
WHERE
  a = %s
  AND b = %(name)s
  AND c = :id
  AND d = $2
  AND e = ?]]
)

sql_case(
  "long argument lists wrap",
  [[select coalesce(some_long_column_name_one, some_long_column_name_two, some_long_column_name_three, 'fallback') from t]],
  [[
SELECT
  coalesce(
    some_long_column_name_one,
    some_long_column_name_two,
    some_long_column_name_three,
    'fallback'
  )
FROM
  t]]
)

sql_case(
  "window function, DISTINCT ON, lateral",
  [[select distinct on (a) a, row_number() over (partition by b order by c desc) rn from t cross join lateral unnest(t.arr) as u(x)]],
  [[
SELECT DISTINCT ON (a)
  a,
  row_number() OVER (PARTITION BY b ORDER BY c DESC) rn
FROM
  t
  CROSS JOIN LATERAL unnest(t.arr) AS u(x)]]
)

sql_case(
  "window frames wrap; set operators between groups",
  [[select sum(x) over (partition by a order by b rows between unbounded preceding and current row) from t; (select 1) intersect (select 2)]],
  [[
SELECT
  sum(x) OVER (
    PARTITION BY a
    ORDER BY b
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  )
FROM
  t;

(
  SELECT
    1
)
INTERSECT
(
  SELECT
    2
)]]
)

sql_case(
  "explain, copy, fetch first, escape",
  [[explain (analyze, buffers) select a from t where a like 'x%' escape '\' fetch first 5 rows only; copy users (id, name) from '/tmp/u.csv' with (format csv)]],
  [[
EXPLAIN (ANALYZE, buffers)
SELECT
  a
FROM
  t
WHERE
  a LIKE 'x%' ESCAPE '\'
FETCH FIRST 5 ROWS ONLY;

COPY users (id, name) FROM '/tmp/u.csv' WITH (format csv)]]
)

for _, c in ipairs(sql_cases) do
  local out, err = dbfmt.format(c.input, "postgres", { indent = 2 })
  check("sql: " .. c.name .. " (no error)", out ~= nil, err)
  if out then
    eq("sql: " .. c.name, out, (c.want:gsub("^\n", "")))
    -- Only whitespace and keyword case may change.
    eq("sql: " .. c.name .. " keeps content", squash(out):lower(), squash(c.input):lower())
    -- Formatting is a fixed point.
    eq("sql: " .. c.name .. " idempotent", dbfmt.format(out, "postgres", { indent = 2 }), out)
  end
end

-- Options
eq(
  "sql: lower keywords",
  dbfmt.format("SELECT a FROM t WHERE b IS NULL", "pg", { keyword_case = "lower" }),
  "select\n  a\nfrom\n  t\nwhere\n  b is null"
)
eq(
  "sql: preserve keywords",
  dbfmt.format("Select a from T", "pg", { keyword_case = "preserve" }),
  "Select\n  a\nfrom\n  T"
)
eq("sql: indent 4", dbfmt.format("select a from t", "pg", { indent = 4 }), "SELECT\n    a\nFROM\n    t")
eq("sql: blank_lines = 0", dbfmt.format("select 1; select 2;", "pg", { blank_lines = 0 }), "SELECT\n  1;\nSELECT\n  2;")

-- Content that must survive untouched
do
  local out = dbfmt.format("select 'it''s  a   string', \"Quoted  Ident\", E'a\\'b', $tag$ x  y $tag$", "pg")
  check(
    "sql: literals preserved",
    out
      and out:find("'it''s  a   string'", 1, true)
      and out:find('"Quoted  Ident"', 1, true)
      and out:find("E'a\\'b'", 1, true)
      and out:find("$tag$ x  y $tag$", 1, true),
    out
  )
end

-- Errors leave callers a clear message instead of garbage
do
  local out, err = dbfmt.format("select 'oops", "pg")
  check("sql: unterminated string rejected", out == nil and err:find("unterminated"), err)
  out, err = dbfmt.format("select (1", "pg")
  check("sql: unbalanced paren rejected", out == nil and err:find("unbalanced"), err)
  out, err = dbfmt.format("select 1)", "pg")
  check("sql: stray paren rejected", out == nil and err:find("unbalanced"), err)
  out, err = dbfmt.format("   ", "pg")
  eq("sql: blank input", out, "")
end

-- plpgsql "END CASE" must not swallow the rest of the file
do
  local out, err = dbfmt.format("case x when 1 then null; end case; select 1;", "pg")
  check("sql: unterminated CASE tolerated", out ~= nil, err)
end

-- CQL dialect
eq(
  "cql: keywords",
  dbfmt
    .format("create keyspace if not exists ks with replication = {'class':'S'}; select * from ks.t allow filtering", "cql")
    :gsub("%s+", " "),
  "CREATE KEYSPACE IF NOT EXISTS ks WITH replication = { 'class': 'S' }; SELECT * FROM ks.t ALLOW FILTERING"
)

---------------------------------------------------------------------------
-- Documents (MongoDB / JSON)
---------------------------------------------------------------------------

local mongo_in = [[use shop
db.users.find({age:{$gt:18},status:"A",name:/^jo/i},{name:1,_id:0}).sort({name:1}).limit(10)
db.orders.aggregate([{$match:{status:"A",created:{$gte:ISODate("2024-01-01T00:00:00Z")}}},{$group:{_id:"$cust_id",total:{$sum:"$amount"},n:{$sum:1}}},{$sort:{total:-1}}]).toArray()

// insert
db.users.insertOne({_id:ObjectId("507f1f77bcf86cd799439011"),tags:["a","b"],address:{city:"X",zip:12345}})
db.users.updateMany({}, {$set:{x:1}}) // done
]]
local mongo_want = [[
use shop
db.users.find(
  { age: { $gt: 18 }, status: "A", name: /^jo/i },
  { name: 1, _id: 0 }
)
  .sort({ name: 1 })
  .limit(10)
db.orders.aggregate([
  {
    $match: { status: "A", created: { $gte: ISODate("2024-01-01T00:00:00Z") } }
  },
  { $group: { _id: "$cust_id", total: { $sum: "$amount" }, n: { $sum: 1 } } },
  { $sort: { total: -1 } }
]).toArray()

// insert
db.users.insertOne({
  _id: ObjectId("507f1f77bcf86cd799439011"),
  tags: ["a", "b"],
  address: { city: "X", zip: 12345 }
})
db.users.updateMany({}, { $set: { x: 1 } }) // done]]

do
  local out, err = dbfmt.format(mongo_in, "mongo")
  check("mongo: formats", out ~= nil, err)
  eq("mongo: golden", out, mongo_want)
  eq("mongo: keeps content", squash(out), squash(mongo_in))
  eq("mongo: idempotent", dbfmt.format(out, "mongo"), out)
end

do
  local out = dbfmt.format([[{"a":1,"b":[1,2,3],"c":{"d":null,"e":[{"f":true}]},"empty":{},"arr":[]}]], "json")
  eq(
    "json: expanded style",
    out,
    [[
{
  "a": 1,
  "b": [1, 2, 3],
  "c": {
    "d": null,
    "e": [
      {
        "f": true
      }
    ]
  },
  "empty": {},
  "arr": []
}]]
  )
  eq("json: idempotent", dbfmt.format(out, "json"), out)
  local parsed = vim.json.decode(out)
  check("json: output is valid JSON", parsed.c.e[1].f == true)
end

eq("json: NDJSON stays line per document", dbfmt.format('{"a":1}\n{"b":2}\n', "mongo"), '{ "a": 1 }\n{ "b": 2 }')

eq(
  "mongo: code blocks are copied verbatim",
  dbfmt.format([[db.items.find({ $where: function() { return this.a>1; } })]], "mongo"),
  [[db.items.find({ $where: function() { return this.a>1; } })]]
)

eq(
  "mongo: comments between entries",
  dbfmt.format('{\n  "a": 1, // one\n  // two\n  "b": 2\n}', "mongo"),
  '{\n  "a": 1,  // one\n  // two\n  "b": 2\n}'
)

eq("mongo: unary minus and numbers", dbfmt.format("{a:-1,b:1.5e3,c:-0.5}", "mongo"), "{ a: -1, b: 1.5e3, c: -0.5 }")
eq("mongo: regex with slash in class", dbfmt.format("{a:/[/]x/i}", "mongo"), "{ a: /[/]x/i }")

do
  local out, err = dbfmt.format('{"a": [1, 2}', "json")
  check("doc: mismatched bracket rejected", out == nil and err:find("unbalanced"), err)
  out, err = dbfmt.format('{"a": "x', "json")
  check("doc: unterminated string rejected", out == nil and err:find("unterminated"), err)
end

---------------------------------------------------------------------------
-- Redis
---------------------------------------------------------------------------

eq(
  "redis: commands",
  dbfmt.format(
    "set user:1 \"hello world\"   ex 10\nconfig get maxmemory\n# comment\n\n\nhset h f1 'v 1' f2 v2",
    "redis"
  ),
  "SET user:1 \"hello world\" ex 10\nCONFIG GET maxmemory\n# comment\n\nHSET h f1 'v 1' f2 v2"
)
do
  local out, err = dbfmt.format('set a "oops', "redis")
  check("redis: unterminated quote rejected", out == nil and err:find("unterminated"), err)
end

---------------------------------------------------------------------------
-- Dialect handling
---------------------------------------------------------------------------

eq("dialect: aliases", dbfmt.resolve("PostgreSQL"), "postgres")
eq("dialect: mongosh alias", dbfmt.resolve("mongosh"), "mongo")
check("dialect: unknown is nil", dbfmt.resolve("oracle") == nil)
do
  local out, err = dbfmt.format("x", "oracle")
  check("dialect: unknown is an error", out == nil and err:find("unknown dialect"), err)
end

---------------------------------------------------------------------------
-- Editor integration
---------------------------------------------------------------------------

local function scratch(ft, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = ft
  vim.bo[buf].shiftwidth = 2
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

do
  local buf = scratch("sql", { "select a,b from t where a=1" })
  vim.cmd("DbFormat")
  eq(
    ":DbFormat uses the filetype",
    table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
    "SELECT\n  a,\n  b\nFROM\n  t\nWHERE\n  a = 1"
  )
end

do
  local buf = scratch("sql", { "select 1;", "select   2;", "select 3;" })
  vim.cmd("2DbFormat")
  eq(
    ":DbFormat honours a range",
    table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
    "select 1;\nSELECT\n  2;\nselect 3;"
  )
end

do
  local buf = scratch("text", { "db.a.find({x:1})" })
  vim.cmd("DbFormat mongodb")
  eq(":DbFormat accepts a dialect", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "db.a.find({ x: 1 })")
end

do
  local buf = scratch("sql", { "select (1" })
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local notified
  local orig = vim.notify
  vim.notify = function(msg)
    notified = msg
  end
  vim.cmd("DbFormat")
  vim.notify = orig
  eq("invalid SQL leaves the buffer untouched", vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], before[1])
  check("invalid SQL reports an error", notified and notified:find("unbalanced"), tostring(notified))
end

do
  local buf = scratch("redis", { "get   k" })
  local result_err, result_lines
  dbfmt.conform.format(dbfmt.conform, { buf = buf, shiftwidth = 2 }, { "get   k" }, function(err, lines)
    result_err, result_lines = err, lines
  end)
  check("conform formatter: no error", result_err == nil, tostring(result_err))
  eq("conform formatter: output", result_lines and result_lines[1], "GET k")

  scratch("lua", { "x" })
  local cur = vim.api.nvim_get_current_buf()
  dbfmt.conform.format(dbfmt.conform, { buf = cur, shiftwidth = 2 }, { "x" }, function(err)
    result_err = err
  end)
  check(
    "conform formatter: unknown filetype reports an error",
    result_err and result_err:find("no dialect"),
    tostring(result_err)
  )
end

dbfmt.register_filetypes()
eq("filetype: .mongodb", vim.filetype.match({ filename = "q.mongodb" }), "mongodb")
eq("filetype: .redis", vim.filetype.match({ filename = "q.redis" }), "redis")
eq("filetype: .pgsql", vim.filetype.match({ filename = "q.pgsql" }), "pgsql")

---------------------------------------------------------------------------

if failures > 0 then
  print(("%d of %d checks failed"):format(failures, count))
  os.exit(1)
end
print(("dbfmt: all %d checks passed"):format(count))
