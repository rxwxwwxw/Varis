-- Spec §14.6, §9.5: coroutines may build worlds, mutate facts and consume
-- iterators between yields; each iterator keeps its snapshot.
--
-- Benchmark: a producer coroutine yields every match of a query over N facts
-- while the main thread keeps inserting and retracting facts between
-- resumptions.  The consumer must still see exactly the N original matches.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { n = 5 },
    large = { n = 40000 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local N = P.n

local function expect(label, got, want)
    assert(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    print(label, got)
end
local function count(iterator)
    local n = 0
    for _ in iterator do n = n + 1 end
    return n
end
local function rejects(label, fn, fragment)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected an error")
    assert(string.find(tostring(err), fragment, 1, true),
           label .. ": wrong error: " .. tostring(err))
    print(label, "error")
end
-- Collects one field of every result as a sorted, space-separated string.
-- Symbols are shown by name, so the text does not depend on result order.
local function collect(iterator, field)
    local items = {}
    for m in iterator do
        local v = m[field]
        items[#items + 1] = type(v) == "symbol" and logic.symbolname(v) or tostring(v)
    end
    table.sort(items)
    return table.concat(items, " ")
end

for i = 1, N do fact item(i) end

-- A producer that yields each match.
local function producer()
    return coroutine.wrap(function()
        for m in query item(?n) do
            coroutine.yield(m.n)
        end
    end)
end

-- A suspended iterator keeps its snapshot, even while another coroutine (here
-- the main thread) changes the world.
local next_item = producer()
local first = next_item()
assert(type(first) == "number")
retract item(1)
retract item(2)
fact item(N + 1)
fact item(N + 2)
local seen = 1
while next_item() do seen = seen + 1 end
expect("consumer saw its snapshot", seen, N)
expect("world has moved on", count(query item(?n)), N)   -- -2 retracted, +2 added

-- Coroutines can create worlds and add facts of their own.
local co = coroutine.create(function()
    local w = logic.world()
    fact w.item(:first)
    coroutine.yield(w)
    fact w.item(:second)
    return "done"
end)
local _, world = coroutine.resume(co)
expect("coroutine-built world, at first yield", count(query world.item(?n)), N + 1)
fact world.item(:from_main)                     -- main thread writes to it too
coroutine.resume(co)
expect("after coroutine finished", count(query world.item(?n)), N + 3)
expect("global untouched by that world", count(query item(?n)), N)

-- Two coroutines interleave over their own snapshots of the same relation.
-- The relation now holds 3, 4, ..., N+2, whose sum is (N+2)(N+3)/2 - 3.
local a, b = producer(), producer()
local sum = 0
for _ = 1, N do
    sum = sum + a() + b()
end
expect("interleaved consumers", sum, 2 * ((N + 2) * (N + 3) // 2 - 3))
expect("first consumer exhausted", a(), nil)
