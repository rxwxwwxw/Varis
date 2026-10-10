-- bench: 300k resume/yield switches
local co = coroutine.wrap(function() local i = 0; while true do i = i + 1; coroutine.yield(i) end end)
local last
for i = 1, 300000 do last = co() end
assert(last == 300000)
