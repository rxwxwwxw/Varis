-- PASS: multi-goal query bodies, shared variables, comparisons, and negation.
relation edge(2)
relation banned(1)
relation pair(2)

fact edge(:a, :b)
fact edge(:a, :c)
fact edge(:a, :j)
fact edge(:b, :d)
fact edge(:c, :e)
fact edge(:j, :d)
fact banned(:e)

local expected = { [":b>:d"] = true, [":j>:d"] = true }
local count = 0
for m in query {
    edge(:a, ?middle),
    edge(?middle, ?target),
    not banned(?target),
    ?middle ~= ?target,
    where (?target ~= :forbidden)
} do
    local key = tostring(m.middle) .. ">" .. tostring(m.target)
    assert(expected[key], "unexpected two-hop result: " .. key)
    expected[key] = nil
    count = count + 1
end
assert(count == 2 and next(expected) == nil)

fact pair(:same, :same)
fact pair(:left, :right)
local equal_count = 0
for m in query pair(?value, ?value) do
    assert(m.value == :same)
    equal_count = equal_count + 1
end
assert(equal_count == 1)
print("PASS 04_conjunctive_queries")
