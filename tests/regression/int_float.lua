local T = dofile((arg[0]:match("^(.*)/") or ".") .. "/harness.lua")
local emit, try = T.emit, T.try
local maxi, mini = math.maxinteger, math.mininteger
-- integer / float boundaries (equality and ordering above 2^53)
local vals = {0, 1, -1, 2^53, 2^53 + 1, 2^63, -2^63, maxi, mini, maxi - 1, mini + 1, 0.5, -0.0, 1e308}
for i, a in ipairs(vals) do
  for j, b in ipairs(vals) do
    emit(i, j, a == b, a < b, a <= b, math.ult(1, 2))
  end
end
emit(maxi + 1 == mini, maxi * 2, mini // -1, mini % -1, maxi // 1.0)
emit(math.tointeger(2^53), math.tointeger(2^63), math.tointeger("8"), math.tointeger(3.5))
emit(7 // 2, -7 // 2, 7 // -2, -7 // -2, 7.5 // 2, -7.5 // 2)
emit(7 % 3, -7 % 3, 7 % -3, -7 % -3, 7.5 % 2, -7.5 % 2, 5.3 % math.huge, -5.3 % math.huge)
try(function() return 1 // 0 end)
try(function() return 1 % 0 end)
emit(1 // 0.0, -1 // 0.0, 0/0 ~= 0/0, 1 % 0.0 ~= 1 % 0.0)
emit(3 | 4, 7 & 2, 5 ~ 3, ~0, 1 << 63, 1 << 64, -1 >> 1, 1 << -1, 2^31 | 0)
try(function() return 1.5 | 0 end)
try(function() return "a" | 0 end)
emit("10" + 5, "0x10" + 0, "1e1" + 0, 10 .. 20, "3" * "4", " 7 " + 1)
emit(tonumber("0x7fffffffffffffff"), tonumber("0xffffffffffffffff"), tonumber("9223372036854775808"),
     tonumber("-9223372036854775808"), tonumber("1e"), tonumber("0x"), tonumber(" 12 "), tonumber("1 2"))
emit(tonumber("z", 36), tonumber("ff", 16), tonumber("-ff", 16), tonumber("8", 8), tonumber("1.0", 10))
emit(math.type(1), math.type(1.0), math.type("1"), math.floor(-3.5), math.ceil(-3.5), math.floor(2^62))
emit(math.abs(mini), math.max(1, 2.5), math.min(-1, -1.0), math.fmod(-7, 3), math.fmod(7, -3))
try(math.fmod, 1, 0)
emit(string.format("%5.2f|%-8d|%+d|%x|%X|%o|%e|%g|%a", 3.14159, 42, 42, 255, 255, 8, 12345.6789, 0.0001, 1.0))
emit(string.format("%q", 1/3), string.format("%q", mini), string.format("%q", 0/0 ~= 0/0))
emit(1e15, 1e16, 123456789012345678, 2^63, -2^63, 1e100, 5 // 0.0, 0.1 + 0.2, 100 / 3)
emit(8 // 3 * 3 + 8 % 3, (-8) // 3 * 3 + (-8) % 3)
-- numeric for loops near the limits
local n = 0
for i = maxi - 2, maxi do n = n + 1 end
emit("for-max", n)
n = 0
for i = mini, mini + 2 do n = n + 1 end
emit("for-min", n)
n = 0
for i = 1, 3, maxi do n = n + 1 end
emit("for-bigstep", n)
n = 0
for i = 10, 1, -3 do n = n + i end
emit("for-neg", n)
for x = 1.0, 2.0, 0.25 do emit("f", x) end
try(function() for i = 1, 10, 0 do end end)
try(function() for i = "a", 2 do end end)
emit(math.maxinteger // -1, math.mininteger // 1)
T.done()
