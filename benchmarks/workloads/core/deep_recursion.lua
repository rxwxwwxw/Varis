-- bench: recursion depth 5000, repeated (exercises deep-frame execution)
local function depth(n) if n == 0 then return 0 end return 1 + depth(n - 1) end
local s = 0
for i = 1, 200 do s = s + depth(5000) end
assert(s == 1000000)
