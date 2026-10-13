-- The world a quality call uses when none is given (manual 6.8): global outside effects; inside
-- an effect, the lexical world of the call itself: the session world in the effect body, an
-- enclosed world block, or the world a helper was written in. How the helper was reached
-- (plain call, tail call, pcall, method, metamethod, iterator, coroutine, deep recursion) does
-- not matter.
quality.define(:coins, {initial = 0, minimum = 0, maximum = 1000})

local child, other = logic.emptyworld(), logic.emptyworld()
quality.initialize(:p, :coins)            quality.set(:p, :coins, 10)
quality.initialize(:p, :coins, child)     quality.set(:p, :coins, 20, child)
quality.initialize(:p, :coins, other)     quality.set(:p, :coins, 30, other)

local get = quality.get
local function global_read() return quality.get(:p, :coins) end
local function global_tail() return get(:p, :coins) end
local function global_chain() return global_tail() end
local function global_protected() return select(2, pcall(quality.get, :p, :coins)) end
local function deep(n) if n == 0 then return quality.get(:p, :coins) end return (deep(n - 1)) end
local other_read, other_caller
logic (other) do
    other_read = function() return quality.get(:p, :coins) end
    other_caller = function(f) return f() end
end
local object = setmetatable({}, {
    __index = function() return quality.get(:p, :coins) end,
    __call = function() return quality.get(:p, :coins) end,
})
function object:read() return quality.get(:p, :coins) end
local function each()
    local done = false
    return function() if not done then done = true return quality.get(:p, :coins) end end
end

-- Outside an effect every one of them reads global.
logic (other) do
    assert(quality.get(:p, :coins) == 10 and other_read() == 10 and global_read() == 10)
end

local seen = {}
storylet look()
    when { quality(:p, :coins, ?n) }
    title "Look"
    choice go effect do
        seen.body = quality.get(:p, :coins)
        seen.alias = get(:p, :coins)
        seen.protected = select(2, pcall(quality.get, :p, :coins))
        seen.global_read = global_read()
        seen.global_tail = global_tail()
        seen.global_chain = global_chain()
        seen.global_protected = global_protected()
        seen.deep = deep(400)
        seen.other_read = other_read()
        seen.other_calls_global = other_caller(global_read)
        seen.index = object.coins
        seen.call = object()
        seen.method = object:read()
        for value in each() do seen.iterator = value end
        seen.coroutine = coroutine.wrap(function() return global_read() end)()
        seen.sorted = (function()
            local got
            table.sort({1, 2}, function(a, b) got = quality.get(:p, :coins) return a < b end)
            return got
        end)()
        logic (other) do
            seen.block = quality.get(:p, :coins)
            seen.block_global_read = global_read()
            seen.block_other_read = other_read()
            seen.block_protected = select(2, pcall(quality.get, :p, :coins))
        end
        seen.after_block = quality.get(:p, :coins)
    end end
end

local session = narrative.new(child)
session:seed(1)
session:choose(session:present().storylets[1].choices[1].token)

local expected = {
    body = 20, alias = 20, protected = 20, after_block = 20, sorted = 20,
    global_read = 10, global_tail = 10, global_chain = 10, global_protected = 10, deep = 10,
    index = 10, call = 10, method = 10, iterator = 10, coroutine = 10,
    other_read = 30, other_calls_global = 10,
    block = 30, block_global_read = 10, block_other_read = 30, block_protected = 30,
}
for name, value in pairs(expected) do
    assert(seen[name] == value, name .. ": expected " .. value .. ", got " .. tostring(seen[name]))
end
for name in pairs(seen) do assert(expected[name], name) end
print("ok")
