-- bench: 10M iteration integer accumulate loop
local s = 0
for i = 1, 10000000 do s = s + i end
assert(s == 50000005000000)
