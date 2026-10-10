-- PASS: mutually recursive local relations, including recursion around a cycle.
relation successor(2)
for i = 0, 5 do
    fact successor(i, (i + 1) % 6)
end

local function parity_queries()
    local relation even(1)
    local relation odd(1)

    fact even(0)
    rule odd(?n) :- even(?p), successor(?p, ?n)
    rule even(?n) :- odd(?p), successor(?p, ?n)

    return query even(?value), query odd(?value)
end

local even_iter, odd_iter = parity_queries()
local function check(iterator, expected)
    local count = 0
    for m in iterator do
        assert(expected[m.value], "wrong parity or duplicate result")
        expected[m.value] = nil
        count = count + 1
    end
    assert(count == 3 and next(expected) == nil)
end
check(even_iter, {[0] = true, [2] = true, [4] = true})
check(odd_iter, {[1] = true, [3] = true, [5] = true})
print("PASS 10_local_mutual_recursion")
