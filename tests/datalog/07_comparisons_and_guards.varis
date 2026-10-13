-- Spec §8.4, §9: relational comparisons and procedural `where` guards.
--
-- num(1..N) and every ordered pair is examined:
--   a <  b : N*(N-1)/2        a == b : N        a ~= b : N*(N-1)
--   a <= b : N*(N+1)/2        a >= b : N*(N+1)/2 a >  b : N*(N-1)/2
-- Guards then pick the primes below N by trial division: pi(30) = 10,
-- pi(20000) = 2262.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { n = 6,   primes_to = 30 },
    large = { n = 150, primes_to = 20000 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local N = P.n

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

for i = 1, N do fact num(i) end

expect("a <  b", count(query { num(?a), num(?b), ?a <  ?b }), N * (N - 1) // 2)
expect("a <= b", count(query { num(?a), num(?b), ?a <= ?b }), N * (N + 1) // 2)
expect("a >  b", count(query { num(?a), num(?b), ?a >  ?b }), N * (N - 1) // 2)
expect("a >= b", count(query { num(?a), num(?b), ?a >= ?b }), N * (N + 1) // 2)
expect("a == b", count(query { num(?a), num(?b), ?a == ?b }), N)
expect("a ~= b", count(query { num(?a), num(?b), ?a ~= ?b }), N * (N - 1))

-- A comparison may use a Lua constant as its other operand.
expect("a <= 3", collect(query { num(?a), ?a <= 3 }, "a"), "1 2 3")
expect("a > 3", count(query { num(?a), ?a > 3 }), N - 3)

-- Equality is relational equality: 2 and 2.0 are the same number.
expect("integer equals float", count(query { num(?a), ?a == 2.0 }), 1)

-- Strings order by their bytes; symbols are only comparable for equality.
for _, w in ipairs({ "pear", "apple", "fig" }) do fact word(w) end
expect("string ordering", collect(query { word(?a), word(?b), ?a < ?b }, "a"), "apple apple fig")
fact thing(:x) fact thing(:y)
expect("symbol equality", count(query { thing(?a), ?a == :x }), 1)
rejects("symbol ordering", function()
    for _ in query { thing(?a), thing(?b), ?a < ?b } do end
end, "attempt to compare")
fact mixed(1) fact mixed("one")
rejects("number vs string ordering", function()
    for _ in query { mixed(?a), ?a < 5 } do end
end, "attempt to compare")

-- Guards: a Lua expression over logic variables, truthy means success.
local function is_prime(n)
    if n < 2 then return false end
    for d = 2, math.floor(math.sqrt(n)) do
        if n % d == 0 then return false end
    end
    return true
end
for i = 1, P.primes_to do fact candidate(i) end
rule prime(?n) :- candidate(?n), where (is_prime(?n))
local primes = {
    [30] = 10, [20000] = 2262,   -- known values of pi(x)
}
expect("primes up to " .. P.primes_to, count(query prime(?n)), primes[P.primes_to])
if SCALE == "small" then
    expect("prime list", collect(query prime(?n), "n"),
           "11 13 17 19 2 23 29 3 5 7")   -- sorted as strings
end

-- Only the first result of a guard matters, and only nil/false fail it.
local function multi() return false, true end
expect("first result false", count(query { num(?a), where (multi()) }), 0)
expect("zero is truthy", count(query { num(?a), where (0) }), N)
expect("empty string is truthy", count(query { num(?a), where ("") }), N)
expect("nil fails", count(query { num(?a), where (nil) }), 0)
expect("false fails", count(query { num(?a), where (false) }), 0)

-- Guards capture ordinary values at registration; later changes are ignored.
local limit = 3
rule below_limit(?a) :- num(?a), where (?a <= limit)
limit = 1000
expect("captured limit", count(query below_limit(?a)), 3)

-- Guards see Lua values, so they may call any pure helper.
expect("guard with string library",
       count(query { word(?w), where (string.sub(?w, 1, 1) == "f") }), 1)
