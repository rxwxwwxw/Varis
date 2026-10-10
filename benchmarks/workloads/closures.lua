local function counter() local c = 0; return function() c = c + 1; return c end end
local total = 0
for i = 1, 200000 do local f = counter(); f(); f(); total = total + f() end
local function compose(f, g) return function(x) return f(g(x)) end end
local inc = function(x) return x + 1 end
local h = inc
for i = 1, 20 do h = compose(h, inc) end
for i = 1, 100000 do total = total + h(i) end
print(total)
