-- logic.counters(): the world model's work counters (performance plan, stage S0 item 4).
-- The exits of stages W1 and W4 are stated in them: a read-only query copies no facts, and a
-- repeated query over unchanged relations derives nothing again.
local function delta(run)
    local before = logic.counters()
    run()
    local after, d = logic.counters(), {}
    for name, value in pairs(after) do
        assert(math.type(value) == "integer" and value >= before[name], name)
        d[name] = value - before[name]
    end
    return d
end

local w = logic.emptyworld()
logic (w) do
    relation edge(a, b)
    for i = 1, 20 do fact edge(i, i + 1) end
    rule path(?a, ?b) :- edge(?a, ?b)
    rule path(?a, ?c) :- path(?a, ?b), edge(?b, ?c)
end

local function count()
    local n = 0
    logic (w) do
        for _ in query { path(1, ?to) } do n = n + 1 end
    end
    return n
end

local first = delta(function() assert(count() == 20) end)
assert(first.queries == 1)
assert(first.tuples_derived == 210, first.tuples_derived)   -- 20 + 19 + ... + 1 pairs
assert(first.rule_firings >= 2)
assert(first.facts_copied == 0)
assert(first.table_rows == 20)                               -- edge frozen once after its writes
assert(first.derived_cache_hits == 0)

local again = delta(function() assert(count() == 20) end)
assert(again.queries == 1 and again.derived_cache_hits == 1)
assert(again.tuples_derived == 0 and again.rule_firings == 0)
assert(again.facts_copied == 0 and again.table_rows == 0)

-- A write rebuilds the written relation's table and invalidates what was derived from it.
local write = delta(function()
    logic (w) do fact edge(21, 22) end
    assert(count() == 21)
end)
assert(write.table_rows == 21 and write.tuples_derived == 231)

local d = delta(function() collectgarbage() end)
assert(d.collections >= 1)
assert(logic.counters().allocated_bytes > 0)
-- Story logic cannot read them.
local ok, message = pcall(function() transaction (w) do logic.counters() end end)
assert(not ok and tostring(message):find("not available", 1, true))
print("ok")
