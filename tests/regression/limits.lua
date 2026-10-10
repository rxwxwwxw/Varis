local T = dofile((arg[0]:match("^(.*)/") or ".") .. "/harness.lua")
local emit, try = T.emit, T.try
local function build(n, fmt, sep) local t = {} for i = 1, n do t[i] = fmt:format(i) end return table.concat(t, sep) end
local function compile(src)
  local f, e = load(src, "=limits")
  e = (e or ""):match("^[^\n]*"):gsub("^limits:%d+: ", "")  -- lua.c appends a traceback to some errors
  return f ~= nil, e
end
-- locals, upvalues, parameters, constants, nesting
emit(compile("local " .. build(200, "v%d", ",") .. " = 1"))
emit(compile("local " .. build(201, "v%d", ",") .. " = 1"))
emit(compile("local function f(" .. build(250, "p%d", ",") .. ") end"))
emit(compile("return {" .. build(5000, "%d.5", ",") .. "}"))
emit(compile("return " .. string.rep("(", 150) .. "1" .. string.rep(")", 150)))
emit(compile("return " .. string.rep("(", 250) .. "1" .. string.rep(")", 250)))
emit(compile(string.rep("do ", 150) .. string.rep("end ", 150)))
emit(compile(string.rep("do ", 250) .. string.rep("end ", 250)))
emit(compile("return " .. string.rep("{", 190) .. string.rep("}", 190)))
emit(compile("return " .. build(300, "%d", " .. ")))
emit(compile("local a = " .. string.rep("a.", 1000) .. "b"))
local up = {}
for i = 1, 100 do up[#up + 1] = ("local u%d = %d"):format(i, i) end
up[#up + 1] = "return function() return " .. build(100, "u%d", "+") .. " end"
emit(load(table.concat(up, "\n"))()())
-- long strings and comments, escapes
local long = string.rep("x", 100000)
emit(#load("return [[" .. long .. "]]")(), load("--[==[" .. long .. "]==] return 1")())
emit(load("return '\\u{7FFFFFFF}'")():byte(1, -1))
emit(compile("return '\\u{80000000}'"))
emit(compile("return '\\xZZ'"))
emit(compile("return '\\300'"))
emit(compile("return 'a\nb'"))
emit(compile("return 0x"))
emit(compile("return 1..2"))
emit(compile("return 3 = 4"))
-- deep recursion handled as errors
local function rec(n) if n == 0 then return 0 end return 1 + rec(n - 1) end
emit(rec(10000))
local ok, msg = pcall(function() local function inf() return 1 + inf() end return inf() end)
emit(ok, (msg:gsub("^[^:]*:%d+: ", ""):gsub("%(.*$", "")))
local ok2, msg2 = pcall(string.rep, "x", -1)
emit(ok2, msg2)
-- string.rep / concat size limits
try(string.rep, "abc", math.maxinteger)
try(function() return ("x"):rep(2^40) end)
-- deeply nested data
local deep = {}
local cur = deep
for i = 1, 5000 do cur.next = {i}; cur = cur.next end
local n = 0
cur = deep
while cur.next do n = n + 1; cur = cur.next end
emit(n)
-- unpack limits
emit(select("#", table.unpack({}, 1, 5000)))
try(table.unpack, {}, 1, 1e7)
emit(#string.format("%s", string.rep("ab", 10000)))
-- many arguments / results
local function many(...) return select("#", ...) end
emit(many(table.unpack({}, 1, 200)))
T.done()
