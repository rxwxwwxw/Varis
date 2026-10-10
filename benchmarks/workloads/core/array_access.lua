-- bench: 1M sequential array stores and loads
local t = {}
for i = 1, 1000000 do t[i] = i end
local sum = 0
for i = 1, 1000000 do sum = sum + t[i] end
assert(sum == 500000500000)
