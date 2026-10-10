local T = dofile((arg[0]:match("^(.*)/") or ".") .. "/harness.lua")
local emit, try = T.emit, T.try
local function sample(a, b, ...)
  local up = a
  local t = {1, 2.5, "three", [10] = true, x = {y = {}}}
  for i = 1, 3 do t[#t + 1] = i * b end
  local s = 0
  for _, v in ipairs(t) do if type(v) == "number" then s = s + v end end
  return s, up, select("#", ...), "str" .. tostring(b)
end
emit(sample(1, 2, "p", "q"))
local d = string.dump(sample)
local f = load(d, "=dumped", "b")
-- upvalue-free function: all values must match
emit(f(1, 2, "p", "q"))
local stripped = load(string.dump(sample, true), "=s", "b")
emit(stripped(1, 2, "p", "q"))
emit(#d > #string.dump(sample, true))
-- stripped chunks lose names but keep behaviour; error positions become "?"
local bad = load(string.dump(function(x) return x.y.z end, true))
try(bad, {})
local named = load(string.dump(function(x) return x.y.z end))
try(named, {})
-- header checks
emit(d:sub(1, 4) == "\27Lua", d:byte(5), d:byte(6))
try(load, d:sub(1, 10))
emit(load(d:sub(1, 20), "=trunc"))
emit(load("return 1", "=x", "b"))
-- upvalues of loaded functions: first is _ENV for main chunks
local g = load("return a, b")
local env = {a = 1, b = 2}
debug.setupvalue(g, 1, env)
emit(g())
local dumped = string.dump(load("return x"))
local h = load(dumped, "=h", "b", {x = "envx"})
emit(h())
try(string.dump, print)
-- chunks with many constants and nested functions survive the round trip
local lines = {"local t = {}"}
for i = 1, 300 do lines[#lines + 1] = ("t[%d] = %d.5 + %d"):format(i, i, i) end
lines[#lines + 1] = "return function(n) return t[n] end"
local big = assert(load(table.concat(lines, "\n")))()
local big2 = assert(load(string.dump(assert(load(table.concat(lines, "\n"))))))()
emit(big(1), big(300), big2(150))
-- dofile/loadfile/require on a generated file
local name = os.tmpname()
local fh = assert(io.open(name, "w"))
fh:write("#!shebang line\nlocal a, b = ...\nreturn (a or 0) + (b or 0), 'from file'\n")
fh:close()
emit(dofile(name))
emit(loadfile(name)(3, 4))
emit(select("#", loadfile("/nonexistent/file.lua")))
os.remove(name)
-- package.path searching and preload
package.preload.virtual = function(n, extra) return {name = n, extra = extra} end
local v = require("virtual")
emit(v.name, v.extra, require("virtual") == v, package.loaded.virtual == v)
try(require, "no.such.module.here")
emit(package.searchpath("nope", "./?.x;./?/init.x"))
T.done()
