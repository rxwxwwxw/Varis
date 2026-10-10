local function sum(...) local s = 0 for i = 1, select('#', ...) do s = s + (select(i, ...)) end return s end
local function pack2(...) return {n = select('#', ...), ...} end
local t = 0
for i = 1, 100000 do t = t + sum(i, 2, 3, 4, 5) + pack2(i, i).n end
print(t)
