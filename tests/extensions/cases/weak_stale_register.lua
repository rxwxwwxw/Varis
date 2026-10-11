-- Regression: a new local's register is reserved before its initializer runs; its stale contents
-- (here the dead local `tmp`) must not keep a weakly referenced object alive during a collection
-- that happens inside the initializer. (The official closure.lua relies on this; dlua's register
-- allocation differs from stock Lua, and loaded chunks were additionally missing live-register data.)
local w = setmetatable({}, {__mode = "v"})
do
    local tmp = {}
    w[1] = tmp
end
local r = tostring(collectgarbage()) .. "x"
assert(w[1] == nil, "weak value kept alive by a stale register")
assert(r == "0x")

-- The same through a binary chunk: dump/load must preserve the live-register data.
local f = load([[
    local w = setmetatable({}, {__mode = "v"})
    do local tmp = {}; w[1] = tmp end
    local r = tostring(collectgarbage()) .. "x"
    return w[1] == nil
]])
local g = load(string.dump(f), "=dumped", "b")
assert(g() == true, "dumped chunk kept a weak value alive")
