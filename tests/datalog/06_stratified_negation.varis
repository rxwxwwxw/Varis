-- Spec §8.1-8.3, §13.2: negation as failure over completed lower strata.
--
-- Nodes 1..N form a chain.  Every third node (3, 6, 9, ...) is blocked.
--   stratum 0: node, edge, blocked            (base facts)
--   stratum 1: open(x)    :- node(x), not blocked(x)
--   stratum 1: step(x,y)  :- edge(x,y), open(x), open(y)
--   stratum 1: reach      transitive closure of step
--   stratum 2: sink(x)    :- open(x), not has_out(x)  with has_out(x) :- reach(x,_)
-- Blocked nodes cut the chain into pieces {3k+1, 3k+2}, so reach holds one
-- pair (3k+1, 3k+2) per piece, and the sinks are the 3k+2 nodes.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { n = 9 },
    large = { n = 3000 },
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

for i = 1, N do
    fact node(i)
    if i % 3 == 0 then fact blocked(i) end
    if i < N then fact edge(i, i + 1) end
end

rule open(?x) :- node(?x), not blocked(?x)
rule step(?x, ?y) :- edge(?x, ?y), open(?x), open(?y)
rule reach(?x, ?y) :- step(?x, ?y)
rule reach(?x, ?z) :- step(?x, ?y), reach(?y, ?z)
rule has_out(?x) :- reach(?x, ?_)
rule sink(?x) :- open(?x), not has_out(?x)

local blocked_count = N // 3
local pairs_expected = N // 3 + ((N % 3 == 2) and 1 or 0)
expect("open nodes", count(query open(?x)), N - blocked_count)
expect("steps", count(query step(?x, ?y)), pairs_expected)
expect("reach", count(query reach(?x, ?y)), pairs_expected)
expect("has_out", count(query has_out(?x)), pairs_expected)
expect("sinks", count(query sink(?x)), N - blocked_count - pairs_expected)

-- Hand-checkable on the small scale: 9 nodes, blocked 3 6 9.
if SCALE == "small" then
    expect("open list", collect(query open(?x), "x"), "1 2 4 5 7 8")
    expect("sink list", collect(query sink(?x), "x"), "2 5 8")
end

-- Adding a fact to a *negated* relation removes derived tuples...
fact blocked(1)
expect("open after blocking 1", count(query open(?x)), N - blocked_count - 1)
expect("reach after blocking 1", count(query reach(?x, ?y)), pairs_expected - 1)
-- ...and 2, now with no incoming step, is open but not a source: still a sink.
expect("2 is a sink", count(query sink(2)), 1)
-- ...and retracting it brings the derived tuples back.
retract blocked(1)
expect("reach after unblocking 1", count(query reach(?x, ?y)), pairs_expected)

-- Negation with a constant: "which nodes are not 5?"
expect("not equal to constant via negation",
       count(query { node(?x), not blocked(?x), ?x ~= 5 }), N - blocked_count - 1)

-- A rule that also uses a guard-free comparison above negation.
rule low_open(?x) :- open(?x), ?x < 5
expect("low open nodes", collect(query low_open(?x), "x"), "1 2 4")

-- Negation cycle: registration is rejected and the program is unchanged.
rule wins(?x) :- node(?x), not loses(?x)
rejects("negation cycle", function()
    rule loses(?x) :- node(?x), not wins(?x)
end, "negation cycle")
expect("rejected rule left program intact", count(query wins(?x)), N)
