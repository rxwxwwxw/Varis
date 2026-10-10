-- Spec §14.4, §16, §9.5, §12.10: every listed error condition is raised as an
-- ordinary Lua error, and a failed operation leaves the program unchanged.
--
-- Each `rejects(label, fn, fragment)` runs fn under pcall and checks that the
-- message contains the fragment.  After each failed *registration* the program
-- is re-queried to show nothing was published.
--
-- Benchmark: the full list of failures is provoked R times.  Failed
-- registrations must not leak partial state, so counts stay constant.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { rounds = 2 },
    large = { rounds = 1500 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local R = P.rounds

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

relation edge(2)
fact edge(:a, :b)
fact edge(:b, :c)
rule path(?x, ?y) :- edge(?x, ?y)
rule path(?x, ?y) :- edge(?x, ?z), path(?z, ?y)
local other = logic.emptyworld()
fact other.source(1)

local failures = 0
local function fails(label, fn, fragment)
    rejects(label, fn, fragment)
    failures = failures + 1
end

-- All of these are provoked once now, and R more times in the benchmark.
local function provoke_all(verbose)
    local run = verbose and fails or function(_, fn, fragment)
        local ok, err = pcall(fn)
        assert(not ok and string.find(tostring(err), fragment, 1, true), tostring(err))
    end
    run("arity mismatch in fact",   function() fact edge(:a) end, "expects arity 2")
    run("arity mismatch in query",  function() local q = query edge(:a) end, "expects arity 2")
    run("arity mismatch in rule",   function() rule bad(?x) :- edge(?x) end, "expects arity 2")
    run("unsafe head variable",     function() rule bad(?x, ?z) :- edge(?x, ?y) end, "in rule head is not bound")
    run("unsafe negated variable",  function() rule bad(?x) :- edge(?x, ?y), not edge(?y, ?z) end, "in negated atom is not bound")
    run("unsafe comparison",        function() rule bad(?x) :- edge(?x, ?y), ?z < 3 end, "in comparison is not bound")
    run("unsafe guard",             function() rule bad(?x) :- edge(?x, ?y), where (?z) end, "?z")
    run("negation cycle",           function()
        rule p1(?x) :- edge(?x, ?y), not p2(?x)
        rule p2(?x) :- edge(?x, ?y), not p1(?x)
    end, "negation cycle")
    run("self negation",            function() rule bad(?x) :- edge(?x, ?y), not bad(?x) end, "negation cycle")
    run("unknown relation in query", function() local q = query nothing(?x) end, "unknown relation")
    run("qualifier is not a world", function() local t = {} fact t.edge(:a, :b) end, "expected world object")
    run("rule on another world",    function() rule bad(?x) :- other.source(?x) end, "cross-world")
    run("NaN in fact",              function() fact edge(0/0, :a) end, "NaN")
    run("NaN in query",             function() local q = query edge(0/0, ?y) end, "NaN")
    run("relation redeclared",      function() relation edge(5) end, "already declared")
    run("world rule on local",      function()
        local relation tmp(1)
        rule bad(?x) :- tmp(?x)
    end, "local relation")
end
provoke_all(true)

-- A failed registration published nothing: no stray relations, results intact.
-- (The negation-cycle pair is the one subtle case: its first rule is a
-- successful statement of its own and stays; only the second was refused.)
expect("failed rules left no relation", pcall(function() local q = query bad(?x) end), false)
expect("first rule of the pair stays", collect(query p1(?x), "x"), "a b")
expect("refused rule left p2 empty", count(query p2(?x)), 0)
expect("path unchanged", count(query path(?x, ?y)), 3)
expect("edge unchanged", count(query edge(?x, ?y)), 2)
expect("failed fact inserted nothing", count(query edge(?x, :a)), 0)

-- Earlier successful statements are not undone by a later failure.
fact edge(:c, :d)
pcall(function() fact edge(:d) end)
expect("earlier fact survives later failure", count(query edge(:c, :d)), 1)
expect("closure includes it", count(query path(:a, :d)), 1)

-- Errors in guards surface when the query runs, once; the iterator is then dead.
local function boom() error("GUARD FAILED") end
local it = query { edge(?x, ?y), where (boom()) }
rejects("guard error at iteration", function() it() end, "GUARD FAILED")
rejects("iterator invalid afterwards", function() it() end, "invalid query iterator")
expect("program still queryable", count(query edge(?x, ?y)), 3)

-- A guard may not yield while the engine is inferring.
local co = coroutine.create(function()
    for _ in query { edge(?x, ?y), where (coroutine.yield("from guard")) } do end
end)
local ok = coroutine.resume(co)
expect("yield inside guard is an error", ok, false)

-- Comparison of unsupported type combinations raises at evaluation.
fact mixed(1) fact mixed(:one)
rejects("number against symbol", function()
    for _ in query { mixed(?v), ?v < 2 } do end
end, "attempt to compare")

-- Library argument checking.
rejects("binding of non-record", function() logic.binding(5, "x") end, "binding record")
rejects("add to non-world", function() logic.add(5, "x", 1) end, "expected world object")
rejects("world from non-world", function() logic.world(5) end, "expected world object")

-- Benchmark.
for _ = 1, R do provoke_all(false) end
expect("path still unchanged", count(query path(:a, ?t)), 3)
expect("provocations per round", failures, 16)
