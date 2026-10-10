-- Spec §11: worlds, snapshot inheritance, independence, qualified references.
--
-- Benchmark: a base world holds a chain of F nodes (F*(F-1)/2 path pairs).
-- C children are created from it; child i attaches a spur node to chain node i,
-- which adds exactly i pairs (nodes 1..i reach the spur).  So child i holds
-- F*(F-1)/2 + i pairs, and the base keeps F*(F-1)/2.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { chain = 5,  children = 3 },
    large = { chain = 25, children = 150 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local F, C = P.chain, P.children

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

-- Inheritance is a snapshot of facts *and* rules at creation time.
fact edge(:a, :b)
rule path(?x, ?y) :- edge(?x, ?y)
rule path(?x, ?y) :- edge(?x, ?z), path(?z, ?y)

local child = logic.world()
expect("child inherits facts", count(query child.edge(?x, ?y)), 1)
expect("child inherits derived", count(query child.path(:a, ?t)), 1)

-- Changes after creation stay where they were made, in both directions.
fact edge(:b, :c)                  -- global only
fact child.edge(:b, :d)            -- child only
expect("global sees :c", collect(query path(:a, ?t), "t"), "b c")
expect("child sees :d", collect(query child.path(:a, ?t), "t"), "b d")

-- The same holds for rules.
rule later(?x) :- edge(?x, ?_)
expect("child lacks later rule", pcall(function() local q = query child.later(?x) end), false)
rule child.child_only(?x) :- edge(?x, ?_)
expect("global lacks child rule", pcall(function() local q = query child_only(?x) end), false)
expect("child rule works", collect(query child.child_only(?x), "x"), "a b")

-- Same name and arity in different worlds are independent relations.
fact child.mark(1)
fact mark(1) fact mark(2)
expect("child mark", count(query child.mark(?m)), 1)
expect("global mark", count(query mark(?m)), 2)

-- An empty world starts with nothing, and querying its relations is an error
-- until they exist.
local isolated = logic.emptyworld()
rejects("empty world has no edge", function()
    local q = query isolated.edge(?x, ?y)
end, "unknown relation")
fact isolated.edge(:z, :z)
expect("fact into empty world", count(query isolated.edge(?x, ?y)), 1)

-- logic.world(parent) snapshots any world, not just the global one.
local grandchild = logic.world(child)
fact child.edge(:d, :e)
expect("grandchild from child", collect(query grandchild.path(:a, ?t), "t"), "b d")
expect("child moved on", collect(query child.path(:a, ?t), "t"), "b d e")

-- The qualifier may be a chain of ordinary field accesses ending in a world.
local game = { state = { arena = logic.emptyworld() } }
fact game.state.arena.edge(:x, :y)
expect("field-chain qualifier", count(query game.state.arena.edge(?a, ?b)), 1)

-- Library forms take a computed relation name.
logic.add(isolated, "dyn", 1, 2)
logic.add(isolated, "dyn", 1, 2)
logic.add(isolated, "dyn", 3, 4)
expect("logic.add", count(query isolated.dyn(?p, ?q)), 2)
logic.retract(isolated, "dyn", 1, 2)
expect("logic.retract", count(query isolated.dyn(?p, ?q)), 1)

-- World blocks set a lexical default world for unqualified names.
local scratch = logic.emptyworld()
logic (scratch) do
    fact thing(1)
    local inner = logic.emptyworld()
    logic (inner) do
        fact thing(2) fact thing(3)
    end
    -- back in 'scratch' once the nested block ended
    expect("inner block world", count(query inner.thing(?t)), 2)
    expect("outer block world", count(query thing(?t)), 1)
    -- a function defined here keeps scratch as its default world
    function scratch_count() return count(query thing(?t)) end
end
fact thing(100) fact thing(101)
expect("closure keeps its block world", scratch_count(), 1)
expect("global default restored", count(query thing(?t)), 2)

-- The world expression is evaluated once, on entry.
local evaluations = 0
local function pick() evaluations = evaluations + 1; return scratch end
logic (pick()) do
    fact thing(7) fact thing(8) fact thing(9)
end
expect("world expression evaluated once", evaluations, 1)
expect("facts went to picked world", count(query scratch.thing(?t)), 4)

-- Referenced Lua objects are shared by identity, never copied.
local shared = {}
fact holder(shared)
local twin = logic.world()
expect("tables shared across worlds", (query twin.holder(?t))().t == shared, true)

-- Guard closures are inherited with their captured values.
local cap = 2
rule big(?x) :- num(?x), where (?x > cap)
fact num(1) fact num(2) fact num(3) fact num(4)
local kid = logic.world()
cap = 0
fact kid.num(5)
expect("global big", collect(query big(?x), "x"), "3 4")
expect("inherited guard keeps capture", collect(query kid.big(?x), "x"), "3 4 5")

-- Benchmark.
local base = logic.emptyworld()
for i = 1, F - 1 do fact base.link(i, i + 1) end
rule base.reach(?x, ?y) :- link(?x, ?y)
rule base.reach(?x, ?y) :- link(?x, ?z), reach(?z, ?y)
local base_pairs = F * (F - 1) // 2
expect("base chain pairs", count(query base.reach(?x, ?y)), base_pairs)

local sum = 0
for i = 1, C do
    local w = logic.world(base)
    local spur = symbol("spur" .. i)
    fact w.link(i % F + 1, spur)    -- attach to chain node (i mod F) + 1
    -- node n = i % F + 1 is reached from nodes 1..n, adding n pairs
    local n = i % F + 1
    local got = count(query w.reach(?x, ?y))
    assert(got == base_pairs + n, "child " .. i .. ": " .. got)
    sum = sum + got
end
local expected_sum = 0
for i = 1, C do expected_sum = expected_sum + base_pairs + (i % F + 1) end
expect("sum over children", sum, expected_sum)
expect("base unchanged", count(query base.reach(?x, ?y)), base_pairs)
