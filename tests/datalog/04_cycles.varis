-- Spec §1.2, §6.3, §18.1: cycles do not make recursive derivation loop.
--
-- Part 1 is the spec's example: a -> b -> c -> a plus c -> d.
--   from :a you can reach a, b, c, d (a through the cycle); nothing leaves d.
-- Part 2 is a ring of N nodes: every node reaches every node, itself included,
-- so the closure has exactly N*N pairs.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { ring = 4 },
    large = { ring = 70 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local N = P.ring

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

-- Part 1.
fact edge(:a, :b)
fact edge(:b, :c)
fact edge(:c, :a)
fact edge(:c, :d)
rule path(?x, ?y) :- edge(?x, ?y)
rule path(?x, ?y) :- edge(?x, ?z), path(?z, ?y)

expect("reachable from a", collect(query path(:a, ?t), "t"), "a b c d")
expect("reachable from c", collect(query path(:c, ?t), "t"), "a b c d")
expect("reachable from d", collect(query path(:d, ?t), "t"), "")
expect("nodes on a cycle", collect(query path(?x, ?x), "x"), "a b c")
expect("all pairs", count(query path(?x, ?y)), 3 * 4)

-- Part 2: ring 1 -> 2 -> ... -> N -> 1.
for i = 1, N do fact ring(i, i % N + 1) end
rule around(?x, ?y) :- ring(?x, ?y)
rule around(?x, ?y) :- ring(?x, ?z), around(?z, ?y)

expect("ring pairs", count(query around(?x, ?y)), N * N)
expect("ring self-reachable", count(query around(?x, ?x)), N)
expect("ring from 1", count(query around(1, ?t)), N)

-- Cut the ring open at one edge: it becomes a chain, and N*N drops to
-- N*(N+1)/2 (node i reaches i..N including itself only via the ring; here
-- no cycle remains, so it reaches only i+1..N).
retract ring(N, 1)
expect("opened ring pairs", count(query around(?x, ?y)), N * (N - 1) // 2)
expect("opened ring self-reachable", count(query around(?x, ?x)), 0)
