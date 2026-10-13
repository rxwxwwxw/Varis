-- bench: table.sort of 100k pseudo-random integers (default and custom comparator)
local seed = 12345
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed end
local t = {}
for i = 1, 100000 do t[i] = rnd() end
local u = {table.unpack(t, 1, 20000)}
table.sort(t)
for i = 2, #t do assert(t[i - 1] <= t[i]) end
table.sort(u, function(a, b) return a > b end)
for i = 2, #u do assert(u[i - 1] >= u[i]) end
