local function bottomUp(d) if d == 0 then return {} end return {bottomUp(d - 1), bottomUp(d - 1)} end
local function check(t) if t[1] then return 1 + check(t[1]) + check(t[2]) end return 1 end
local total = 0
for i = 1, 20 do total = total + check(bottomUp(14)) end
print(total)
