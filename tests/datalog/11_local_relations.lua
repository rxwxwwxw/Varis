-- Spec §10, §14.3, §18.4: lexically scoped relations.
--
-- Benchmark: a chain 1 -> 2 -> ... -> M.  reachable_from(s) builds a fresh
-- local recursive relation that reaches M - s nodes.  Calling it for
-- s = 1..S therefore finds (M-1) + (M-2) + ... + (M-S) nodes in total.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { m = 6,  starts = 3 },
    large = { m = 120, starts = 60 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local M, S = P.m, P.starts

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

for i = 1, M - 1 do fact edge(i, i + 1) end

-- Each call declares and populates its own local relation.
local function reachable_from(start)
    local relation reachable(1)
    rule reachable(?x) :- edge(start, ?x)
    rule reachable(?x) :- reachable(?y), edge(?y, ?x)
    return query reachable(?node)
end
expect("from 1", count(reachable_from(1)), M - 1)
expect("from M-1", count(reachable_from(M - 1)), 1)

-- The relation is private: it never entered the global world.
rejects("local relation not global", function()
    local q = query reachable(?node)
end, "unknown relation")

-- An iterator outlives its function; later facts do not leak into it.
local held = reachable_from(1)
fact edge(M, M + 1)
expect("held iterator keeps snapshot", count(held), M - 1)
expect("new call sees new fact", count(reachable_from(1)), M)
retract edge(M, M + 1)

-- Two live local relations from different calls are independent.
local a, b = reachable_from(M - 2), reachable_from(M - 3)
expect("relation of the call from M-2", count(a), 2)
expect("relation of the call from M-3", count(b), 3)

-- Local relations may use other local relations and world relations.
local function two_hops(start)
    local relation first(1)
    local relation second(1)
    rule first(?x) :- edge(start, ?x)
    rule second(?y) :- first(?x), edge(?x, ?y)
    return query second(?y)
end
expect("local uses local", (two_hops(1))().y, 3)

-- Local relations shadow world relations of the same name...
fact label(:global)
do
    local relation label(1)
    fact label(:local_one)
    fact label(:local_two)
    expect("local shadows world", count(query label(?l)), 2)
    -- A world-qualified reference bypasses local lookup.
    expect("qualified name bypasses local", collect(query logic.global.label(?l), "l"), "global")
end
-- ...and the world relation is visible again after the block.
expect("world relation after block", collect(query label(?l), "l"), "global")

-- Ordinary Lua locals live in a different namespace and shadow nothing.
local label = "just a string"
expect("lua local does not shadow", collect(query label(?l), "l"), "global")

-- A second declaration shadows the first; rules registered earlier still
-- refer to the original relation, and a query built earlier keeps using it.
do
    local relation item(1)
    fact item(:old)
    local old_query = query item(?x)
    local relation item(1)               -- new, empty relation named item
    expect("new declaration starts empty", count(query item(?x)), 0)
    fact item(:new)
    expect("new relation sees new fact", collect(query item(?x), "x"), "new")
    expect("old query keeps old relation", collect(old_query, "x"), "old")
end

-- A local relation is tied to the default world active when it was created,
-- even if it is queried after leaving that world block.
local lab = logic.emptyworld()
fact lab.node(:p) fact lab.node(:q)
local lab_iterator
logic (lab) do
    local relation copy(1)
    rule copy(?x) :- node(?x)           -- 'node' resolves in lab
    lab_iterator = query copy(?x)
end
expect("local relation keeps its world", collect(lab_iterator, "x"), "p q")

-- A world-owned rule may not depend on a local relation (it would keep a
-- temporary relation alive forever); a failed attempt changes nothing.
do
    local relation temp(1)
    fact temp(1)
    rejects("world rule on local relation", function()
        rule persistent(?x) :- temp(?x)
    end, "local relation")
    rejects("failed rule left no relation", function()
        local q = query persistent(?x)
    end, "unknown relation")
end

-- Local mutual recursion: nodes at odd distance from a start node.
local function odd_targets(start)
    local relation odd(1)
    local relation even(1)
    rule odd(?x) :- edge(start, ?x)
    rule even(?y) :- odd(?x), edge(?x, ?y)
    rule odd(?y) :- even(?x), edge(?x, ?y)
    return query odd(?n)
end
-- From 1 on the chain, nodes 2, 4, 6 ... are at odd distance... node d+1 is at
-- distance d, so the odd-distance nodes are 2, 4, 6, ...
local want = 0
for n = 2, M, 2 do want = want + 1 end
expect("local mutual recursion", count(odd_targets(1)), want)

-- Benchmark: S independent local fixed points.
local total = 0
for s = 1, S do
    total = total + count(reachable_from(s))
end
local expected = 0
for s = 1, S do expected = expected + (M - s) end
expect("total reachable over starts", total, expected)
