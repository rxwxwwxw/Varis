local N = 200000
local t = {}
local seed = 42
for i = 1, N do seed = (seed * 1103515245 + 12345) % 2147483648; t[i] = seed end
table.sort(t)
for i = 2, N do assert(t[i-1] <= t[i]) end
local u = {}
for i = 1, 50000 do u[i] = {k = (i * 7919) % 10007, v = i} end
table.sort(u, function(a, b) return a.k < b.k or (a.k == b.k and a.v < b.v) end)
print(u[1].k, u[#u].k)
local q = {}
for i = 1, 100000 do table.insert(q, i) end
for i = 1, 100000 do table.remove(q) end
for i = 1, 20000 do table.insert(q, 1, i) end
print(#q)
