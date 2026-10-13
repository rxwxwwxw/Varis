-- Spec §6.3, §13.1: a classic recursive Datalog workload, "same generation".
--
-- A complete binary tree of depth D is stored as parent(p, c) facts using heap
-- numbering: node i has children 2i and 2i+1, the root is 1, level L holds the
-- nodes 2^L .. 2^(L+1)-1.  Two nodes are in the same generation when they are
-- equal or when their parents are.  Every pair on the same level qualifies, so
--     sg holds  sum over L of (2^L)^2 = (4^(D+1) - 1) / 3  pairs.
-- D = 2: 1 + 4 + 16 = 21.   D = 7: 1 + 4 + ... + 16384 = 21845.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { depth = 2 },
    large = { depth = 7 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local D = P.depth

local function expect(label, got, want)
    assert(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    print(label, got)
end
local function count(iterator)
    local n = 0
    for _ in iterator do n = n + 1 end
    return n
end

local last = (1 << (D + 1)) - 1          -- highest node number
for i = 1, last do
    fact node(i)
    if i > 1 then fact parent(i // 2, i) end
end

rule sg(?x, ?x) :- node(?x)
rule sg(?x, ?y) :- parent(?p, ?x), sg(?p, ?q), parent(?q, ?y)

local want = ((1 << (2 * (D + 1))) - 1) // 3
expect("nodes", count(query node(?n)), last)
expect("same-generation pairs", count(query sg(?x, ?y)), want)

-- Cousins of the first node on the deepest level: that whole level.
local first_leaf = 1 << D
expect("peers of the first leaf", count(query sg(first_leaf, ?y)), 1 << D)
expect("peers of the root", count(query sg(1, ?y)), 1)

-- Nodes on different levels are never in the same generation.
expect("root and leaf", count(query sg(1, first_leaf)), 0)
if SCALE == "small" then
    -- Depth 2: level 1 = {2,3}, level 2 = {4,5,6,7}.
    expect("peers of 2", count(query sg(2, ?y)), 2)
    expect("peers of 4", count(query sg(4, ?y)), 4)
end
