local T = dofile((arg[0]:match("^(.*)/") or ".") .. "/harness.lua")
local emit, try = T.emit, T.try
local function gen(n) return coroutine.wrap(function() for i = 1, n do coroutine.yield(i) end return "done" end) end
local g = gen(3)
emit(g(), g(), g(), g())
try(g)
-- resume/yield value passing and status
local co = coroutine.create(function(a, b)
  emit("start", a, b)
  local c = coroutine.yield(a + b)
  emit("got", c)
  local d, e = coroutine.yield(c * 2)
  emit("got2", d, e)
  return "fin", 99
end)
emit(coroutine.status(co), coroutine.resume(co, 1, 2))
emit(coroutine.status(co), coroutine.resume(co, 10))
emit(coroutine.resume(co, "x", "y"))
emit(coroutine.status(co), coroutine.resume(co))
-- running / isyieldable / wrap inside wrap
emit(coroutine.isyieldable(), select(2, coroutine.running()))
local outer = coroutine.wrap(function()
  local inner = coroutine.wrap(function() coroutine.yield("i1"); return "i2" end)
  coroutine.yield(inner())
  coroutine.yield(inner())
  return coroutine.isyieldable()
end)
emit(outer(), outer(), outer())
-- errors: protected inside, propagated outside, error objects keep identity
local errobj = {code = 7}
local c2 = coroutine.create(function() error(errobj) end)
local ok, e = coroutine.resume(c2)
emit(ok, e == errobj, coroutine.status(c2))
local c3 = coroutine.create(function() local x = nil; return x.y end)
emit(coroutine.resume(c3))
-- yield across pcall and metamethods
local c4 = coroutine.wrap(function()
  local ok, v = pcall(function() return coroutine.yield("in pcall") + 1 end)
  coroutine.yield(ok, v)
  local mt = setmetatable({}, {__index = function(_, k) return coroutine.yield("idx " .. k) end})
  return mt.foo
end)
emit(c4(), c4(41))
emit(c4(), c4("meta result"))
-- yield from the main thread and wrong-state resumes
try(coroutine.yield, 1)
local dead = coroutine.create(function() end)
coroutine.resume(dead)
emit(coroutine.resume(dead))
emit(pcall(coroutine.resume, nil))
-- close, with pending to-be-closed variables
local log = {}
local c5 = coroutine.create(function()
  local r <close> = setmetatable({}, {__close = function() log[#log + 1] = "closed" end})
  coroutine.yield(1)
end)
coroutine.resume(c5)
emit(coroutine.close(c5), coroutine.status(c5), log[1])
emit(coroutine.close(coroutine.create(function() end)))
local c6 = coroutine.create(function() error("x") end)
coroutine.resume(c6)
emit(coroutine.close(c6))
-- producer / consumer with a table of results
local function producer() return coroutine.create(function() for i = 1, 5 do coroutine.yield(i * i) end end) end
local p, sum = producer(), 0
while true do
  local ok, v = coroutine.resume(p)
  if not v then break end
  sum = sum + v
end
emit(sum, coroutine.status(p))
-- many coroutines alive at once
local cs = {}
for i = 1, 200 do cs[i] = coroutine.wrap(function(x) while true do x = coroutine.yield(x + i) end end) end
local total = 0
for round = 1, 3 do for i = 1, 200 do total = total + cs[i](round) end end
emit(total)
-- wrap closes the coroutine on error
local w = coroutine.wrap(function() error("bad", 0) end)
try(w)
try(w)
T.done()
