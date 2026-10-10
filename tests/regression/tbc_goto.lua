local T = dofile((arg[0]:match("^(.*)/") or ".") .. "/harness.lua")
local emit, try = T.emit, T.try
local log = {}
local function res(name, fail)
  return setmetatable({}, {__close = function(_, err)
    log[#log + 1] = name .. (err and (":" .. tostring(err):gsub("^[^:]*:%d+: ", "")) or "")
    if fail then error(fail, 0) end
  end})
end
local function flush() local s = table.concat(log, ","); log = {}; return s end
-- normal exit, break, goto, return all close in reverse order
do local a <close> = res("a"); local b <close> = res("b") end
emit(flush())
for i = 1, 2 do local c <close> = res("c" .. i); if i == 1 then goto cont end; log[#log + 1] = "body" ::cont:: end
emit(flush())
local function ret() local d <close> = res("d"); local e <close> = res("e"); return "r" end
emit(ret(), flush())
while true do local f <close> = res("f"); break end
emit(flush())
-- errors: the error object reaches the handler; errors in handlers replace it
emit(pcall(function() local g <close> = res("g"); error("boom", 0) end))
emit(flush())
emit(pcall(function() local h <close> = res("h", "close-fail"); error("orig", 0) end))
emit(flush())
emit(pcall(function() local i <close> = res("i", "first"); local j <close> = res("j", "second") end))
emit(flush())
-- nil and false are allowed; other values need __close
do local n <close> = nil; local f <close> = false end
try(function() local bad <close> = {} end)
try(function() local bad <close> = 42 end)
-- const
try(load, "local x <const> = 1; x = 2")
emit(load("local x <const> = 1; return x + 1")())
-- tbc in coroutines closed explicitly and by wrap errors
local co = coroutine.create(function() local k <close> = res("k"); coroutine.yield(1) end)
coroutine.resume(co)
emit(coroutine.close(co), flush())
-- generic for closing value (4th value)
local function iter() return function(_, i) i = i + 1; if i <= 3 then return i end end, nil, 0, res("loop") end
for i in iter() do log[#log + 1] = "i" .. i end
emit(flush())
for i in iter() do if i == 2 then break end end
emit(flush())
-- goto semantic checks
emit(load("goto l1; local a; ::l1:: print(a)"))
emit(load("do goto l1 end ::l1::") ~= nil)
emit(load("::l1:: ::l1::"))
emit(load("goto nope"))
emit(load("repeat local x; goto c; local y; ::c:: until y"))
-- nested loops with goto out and labels at block end
local count = 0
for i = 1, 3 do
  for j = 1, 3 do
    if j == 2 then goto next_i end
    count = count + 1
  end
  ::next_i::
end
emit(count)
-- integer vs float for-loop var types and loop var copies
for i = 1, 3 do local j = i; i = i * 10; log[#log + 1] = i .. "/" .. j end
emit(flush())
T.done()
