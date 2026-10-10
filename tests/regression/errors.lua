local T = dofile((arg[0]:match("^(.*)/") or ".") .. "/harness.lua")
local emit, try = T.emit, T.try
local t = {}
local function fn() end
-- messages carry variable names for locals, upvalues, globals, fields, methods and constants
local up = nil
try(function() local a; return a.x end)
try(function() return up.x end)
try(function() return undefinedglobal.x end)
try(function() return t.field.sub end)
try(function() return t:nomethod() end)
try(function() local a = {}; a.b.c = 1 end)
try(function() return ("x")() end)
try(function() local s = "a"; return s + 1 end)
try(function() return {} + 1 end)
try(function() return t.a + 1 end)
try(function() local a = {}; return a < 1 end)
try(function() return #nil end)
try(function() return nil .. "x" end)
try(function() undefinedfunc() end)
try(function() t.x.y() end)
try(function() return math.floor("x") end)
try(function() return ("x"):rep({}) end)
try(function() return setmetatable(1, {}) end)
try(function() return tostring() end)
try(function() return ipairs() end)
try(function() return string.sub() end)
try(function() string.format("%d", "x") end)
try(function() return select("x") end)
try(function() return rawset(1, 2, 3) end)
try(function() return tonumber({}, 10) end)
try(function() return math.random(1, 2, 3) end)
try(function() return math.random(2, 1) end)
try(function() local a <const> = 1; return load("local a <const> = 1; a = 2") end)
-- error levels and non-string error values
try(error)
try(error, nil)
try(error, "msg", 0)
try(function() error("lvl1", 1) end)
try(function() error("lvl2", 2) end)
try(function() local function inner() error("deep", 2) end; inner() end)
try(error, 42)
try(error, true)
emit(select("#", pcall(error)))
local e = setmetatable({}, {__tostring = function() return "custom" end})
emit(pcall(error, e))
-- xpcall with handlers and tracebacks (only the first line is compared)
emit(xpcall(function() error("x") end, function(m) return "handled: " .. m end))
emit(xpcall(function() return "fine", 2 end, print))
emit(xpcall(function() error({}) end, function(m) return type(m) end))
emit(xpcall(function() local x = nil; x() end, function(m) return (m:gsub("^[^:]+:%d+: ", "")) end))
emit((debug.traceback("tb", 1):match("^[^\n]+")))
local ok, tb = xpcall(function() error("E") end, debug.traceback)
emit(ok, tb:match("^[^\n]+\n[^\n]+"))
-- error inside the handler, nested pcall
emit(xpcall(function() error("a") end, function() error("b") end))
emit(pcall(pcall, error, "e"))
emit(pcall(pcall))
-- assert variants
try(assert, false)
try(assert, nil, "custom message")
try(assert, false, {1})
emit(assert(1, "unused"), select("#", assert(1, 2, 3)))
-- load syntax errors
for _, src in ipairs{"x =", "x = = 1", "for", "if x then", "return return", "x = 'unterminated",
    "goto nolabel", "break", "local x <foo> = 1", "::a:: ::a::", "x = 1e", "return ...", "f(", "a.b:c = 1",
    "local t = {1,2", "x = [[long", "--[[ comment", "\27Lua"} do
  local f, err = load(src, "=src")
  emit(f == nil, err)
end
emit(load("return 1", "=name", "b"))
emit(load(string.dump(function() end), "=n", "t"))
emit(load(function() return nil end))
local parts = {"return ", "1 + ", "2"}
local i = 0
emit(load(function() i = i + 1; return parts[i] end)())
T.done()
