-- PASS: recursive fixed point, cycles, duplicate-free answers, ground queries.
relation edge(2)
relation path(2)

fact edge(:a, :b)
fact edge(:b, :c)
fact edge(:c, :a) -- cycle
fact edge(:c, :d)
fact edge(:island, :elsewhere)

rule path(?x, ?y) :- edge(?x, ?y)
rule path(?x, ?y) :- edge(?x, ?z), path(?z, ?y)

local expected = {[:a] = true, [:b] = true, [:c] = true, [:d] = true}
local count = 0
for m in query path(:a, ?target) do
    assert(expected[m.target], "unexpected reachable target")
    expected[m.target] = nil
    count = count + 1
end
assert(count == 4)
assert(next(expected) == nil, "a reachable target was missing")

local yes = 0
for m in query path(:a, :a) do
    assert(m ~= nil)
    yes = yes + 1
end
assert(yes == 1, "a true ground query returns exactly one empty binding")

local no = 0
for _ in query path(:island, :a) do no = no + 1 end
assert(no == 0)
print("PASS 02_recursive_reachability")
