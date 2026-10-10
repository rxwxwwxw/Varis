-- PASS: local relations in functions and query iterators escaping their scope.
relation edge(2)
fact edge(:a, :b)
fact edge(:z, :w)

local function reachable_from(start)
    local relation reachable(1)

    rule reachable(?x) :- edge(start, ?x)
    rule reachable(?x) :- reachable(?y), edge(?y, ?x)

    return query reachable(?destination)
end

local function check(iter, expected)
    local count = 0
    for m in iter do
        assert(expected[m.destination], "unexpected local-relation result")
        expected[m.destination] = nil
        count = count + 1
    end
    assert(count > 0 and next(expected) == nil)
end

local before = reachable_from(:a)
local separate = reachable_from(:z)
fact edge(:b, :c)

-- Existing iterators see earlier snapshots.
check(before, {[:b] = true})
check(separate, {[:w] = true})
check(reachable_from(:a), {[:b] = true, [:c] = true})
print("PASS 09_local_relation_closures")
