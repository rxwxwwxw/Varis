-- bench: table.insert / table.remove at the tail, and unpack/concat
local t = {}
for i = 1, 300000 do table.insert(t, i) end
local s = 0
while #t > 0 do s = s + table.remove(t) end
assert(s == 300000 * 300001 // 2)
local parts = {}
for i = 1, 50000 do parts[i] = tostring(i) end
assert(#table.concat(parts, ",") == 288893)
