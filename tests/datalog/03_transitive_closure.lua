-- Spec §6.3, §13.1, §18.1: recursive rules reach a least fixed point.
--
-- The graph is a chain 1 -> 2 -> ... -> N.  Node i reaches every j > i, so the
-- closure holds N*(N-1)/2 pairs; 1 reaches N-1 nodes and N is reached by N-1.
-- Three formulations of the same closure must agree: right recursion, left
-- recursion and (doubly recursive) "path of paths".
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { n = 5,   quad = 5 },
    large = { n = 70, quad = 30 },
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

relation edge(2)
for i = 1, N - 1 do fact edge(i, i + 1) end

-- Right recursion: path(x,y) if edge(x,z) and path(z,y).
rule right(?x, ?y) :- edge(?x, ?y)
rule right(?x, ?y) :- edge(?x, ?z), right(?z, ?y)

-- Left recursion: path(x,y) if path(x,z) and edge(z,y).
rule left(?x, ?y) :- edge(?x, ?y)
rule left(?x, ?y) :- left(?x, ?z), edge(?z, ?y)

expect("right pairs", count(query right(?a, ?b)), N * (N - 1) // 2)
expect("left pairs", count(query left(?a, ?b)), N * (N - 1) // 2)
expect("right from 1", count(query right(1, ?t)), N - 1)
expect("right into N", count(query right(?s, N)), N - 1)
expect("left from 1", count(query left(1, ?t)), N - 1)
expect("no path backwards", count(query right(N, 1)), 0)
expect("path 1 to N exists", count(query right(1, N)), 1)

-- A node never reaches itself on a chain.
expect("no self paths", count(query right(?x, ?x)), 0)

-- Both recursive formulations are the same relation, tuple for tuple.
expect("left but not right", count(query { left(?a, ?b), not right(?a, ?b) }), 0)
expect("right but not left", count(query { right(?a, ?b), not left(?a, ?b) }), 0)

-- Quadratic ("doubly recursive") closure over a shorter chain of Q nodes.
local Q = P.quad
for i = 1, Q - 1 do fact link(i, i + 1) end
rule hop(?x, ?y) :- link(?x, ?y)
rule hop(?x, ?y) :- hop(?x, ?z), hop(?z, ?y)
expect("doubly recursive pairs", count(query hop(?a, ?b)), Q * (Q - 1) // 2)

-- The small chain is small enough to list by hand: from 1 you reach 2 3 4 5.
if SCALE == "small" then
    expect("targets of 1", collect(query right(1, ?t), "t"), "2 3 4 5")
    expect("sources of 5", collect(query right(?s, 5), "s"), "1 2 3 4")
end
