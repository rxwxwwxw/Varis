-- PASS: guards receive typed Lua values, and rule captures happen at registration.
relation weighted_edge(3)
relation affordable(2)

fact weighted_edge(:a, :b, 4)
fact weighted_edge(:a, :c, 3)
fact weighted_edge(:a, :d, 8)
fact weighted_edge(:a, :e, 2)

local threshold = 5
local function is_even(n)
    return n % 2 == 0
end

rule affordable(?from, ?to) :-
    weighted_edge(?from, ?to, ?cost),
    where (?cost <= threshold and is_even(?cost))

-- The change must not alter already registered rule captures.
threshold = 0
local seen = {}
local count = 0
for m in query affordable(:a, ?dest) do
    assert(not seen[m.dest])
    seen[m.dest] = true
    count = count + 1
end
assert(count == 2)
assert(seen[:b] and seen[:e])
assert(not seen[:c] and not seen[:d])
print("PASS 05_pure_guards_and_capture")
