-- A hook installed while a function is running takes effect at that function's next instruction,
-- however the code that installed it was reached: a call, a metamethod of any operator, a close
-- handler, an iterator, pcall or a coroutine. (The interpreter runs a loop without hook code
-- until it sees the request at a safepoint; every instruction that can call out is one.)
local trace
local function hook(_, line) trace[#trace + 1] = line end
local function install() debug.sethook(hook, "l") end
local mt = setmetatable({}, {
    __add = function() install() return 1 end, __index = function() install() return 2 end,
    __lt = function() install() return true end, __len = function() install() return 3 end,
    __close = function() install() end, __concat = function() install() return "x" end,
    __call = function() install() end, __eq = function() install() return true end,
    __newindex = function() install() end, __unm = function() install() return 4 end,
})
local other = setmetatable({}, getmetatable(mt))

local BASE = debug.getinfo(1, "l").currentline
local function run(kind, depth)
    if depth > 0 then return (run(kind, depth - 1)) end
    local x = 0
    if kind == 1 then install()
    elseif kind == 2 then x = mt + 1
    elseif kind == 3 then x = mt.field
    elseif kind == 4 then x = (mt < mt) and 1 or 2
    elseif kind == 5 then x = #mt
    elseif kind == 6 then do local c <close> = mt end
    elseif kind == 7 then x = mt .. "y"
    elseif kind == 8 then mt()
    elseif kind == 9 then for _ in function() install() end do end
    elseif kind == 10 then pcall(install)
    elseif kind == 11 then coroutine.wrap(function() end)() install()
    elseif kind == 12 then x = (mt == other) and 1 or 2
    elseif kind == 13 then mt.field = 1
    elseif kind == 14 then x = -mt
    end
    x = 0
    local y = x * 2 + 9
    for i = 1, 2 do y = y + i end
    while y > 0 do y = y - 5 end
    repeat y = y + 1 until y >= 0
    debug.sethook()
    return y
end
local TAIL = BASE + 19          -- the line of `x = 0` after the chain: no call precedes it

local function lines_of(kind, depth)
    trace = {}
    run(kind, depth)
    local kept = {}
    for _, line in ipairs(trace) do
        if line >= TAIL then kept[#kept + 1] = line - TAIL end
    end
    return table.concat(kept, ",")
end

local expected = lines_of(1, 0)
-- Every line of the tail is reported, starting with the statement right after the chain:
-- x = 0, local y, the for and while lines once per test of their condition, the repeat line once
-- per pass, debug.sethook.
assert(expected == "0,1,2,2,3,3,3,3,4,4,4,5", expected)
for _, depth in ipairs {0, 3, 300} do
    for kind = 1, 14 do
        local got = lines_of(kind, depth)
        assert(got == expected, "kind " .. kind .. " depth " .. depth .. ": " .. got .. " instead of " .. expected)
    end
end
print("ok")
