-- Spec §5.3-5.4, §4.4, §13.3, §18.7: derived relations follow the facts.
--
-- Chain 1 -> 2 -> ... -> N and its closure `path`.  Cutting edge k -> k+1
-- leaves two chains of k and N-k nodes, so the closure keeps
-- k*(k-1)/2 + (N-k)*(N-k-1)/2 pairs.  Restoring the edge restores all N*(N-1)/2.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { n = 6,  rounds = 5 },
    large = { n = 50, rounds = 49 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local N, R = P.n, P.rounds

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

local function chain_pairs(k) return k * (k - 1) // 2 end
local FULL = chain_pairs(N)

for i = 1, N - 1 do fact edge(i, i + 1) end
rule path(?x, ?y) :- edge(?x, ?y)
rule path(?x, ?y) :- edge(?x, ?z), path(?z, ?y)

expect("closure of full chain", count(query path(?x, ?y)), FULL)

-- Cut in the middle, then restore.
local k = N // 2
retract edge(k, k + 1)
expect("closure after cut", count(query path(?x, ?y)), chain_pairs(k) + chain_pairs(N - k))
expect("1 no longer reaches N", count(query path(1, N)), 0)
fact edge(k, k + 1)
expect("closure after restore", count(query path(?x, ?y)), FULL)

-- Base and derived parts are independent: the tuple path(1,3) is derivable,
-- and may also be inserted as a base fact.  Removing the base copy leaves it.
fact path(1, 3)
expect("base+derived tuple counted once", count(query path(1, 3)), 1)
retract path(1, 3)
expect("still derivable after retract", count(query path(1, 3)), 1)

-- A purely derived tuple cannot be retracted; retract only removes base tuples.
retract path(1, 2)
expect("retract does not remove derivations", count(query path(1, 2)), 1)

-- Negation: adding to the negated relation removes derived tuples.
for i = 1, N do fact node(i) end
rule available(?x) :- node(?x), not blocked(?x)
expect("available initially", count(query available(?x)), N)
fact blocked(1)
fact blocked(2)
expect("available after blocking two", count(query available(?x)), N - 2)
retract blocked(1)
expect("available after unblocking one", count(query available(?x)), N - 1)

-- Benchmark: R rounds, each cutting a different edge and checking the closure.
local checks = 0
for i = 1, R do
    retract edge(i, i + 1)
    local got = count(query path(?x, ?y))
    assert(got == chain_pairs(i) + chain_pairs(N - i), "round " .. i)
    fact edge(i, i + 1)
    checks = checks + 1
end
expect("rounds verified", checks, R)
expect("closure at the end", count(query path(?x, ?y)), FULL)
