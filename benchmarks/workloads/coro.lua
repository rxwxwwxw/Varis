local co = coroutine.wrap(function() local i = 0; while true do i = i + 1; coroutine.yield(i) end end)
local s = 0
for i = 1, 200000 do s = s + co() end
local gen = function(n) return coroutine.wrap(function() for i = 1, n do coroutine.yield(i) end end) end
for v in gen(100000) do s = s + v end
print(s)
