-- Spec §6.4, §8.4: a three-way self-join with ordering constraints, the shape
-- of most real-world Datalog queries.
--
-- The graph is the complete graph on n nodes.  Counting each triangle once
-- (a < b < c) gives C(n,3) = n(n-1)(n-2)/6 results:  n=5: 10,  n=30: 4060.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { n = 5 },
    large = { n = 30 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local n = P.n

local function expect(label, got, want)
    assert(got == want, label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    print(label, got)
end
local function count(iterator)
    local c = 0
    for _ in iterator do c = c + 1 end
    return c
end

-- Both directions are stored, so link is symmetric.
for a = 1, n do
    for b = 1, n do
        if a ~= b then fact link(a, b) end
    end
end
expect("links", count(query link(?a, ?b)), n * (n - 1))

-- Ordering constraints select each unordered triangle once.
rule triangle(?a, ?b, ?c) :-
    link(?a, ?b), link(?b, ?c), link(?a, ?c),
    ?a < ?b, ?b < ?c
expect("triangles", count(query triangle(?a, ?b, ?c)), n * (n - 1) * (n - 2) // 6)

-- The same count without the rule, as a braced query.
expect("triangles via query", count(query {
    link(?a, ?b), link(?b, ?c), link(?a, ?c), ?a < ?b, ?b < ?c
}), n * (n - 1) * (n - 2) // 6)

-- Without the ordering constraints each triangle appears in 6 orientations.
expect("ordered triangles", count(query {
    link(?a, ?b), link(?b, ?c), link(?a, ?c)
}), n * (n - 1) * (n - 2))

-- A guard on top: triangles whose corner sum is even.
local even_sum = 0
for a = 1, n do for b = a + 1, n do for c = b + 1, n do
    if (a + b + c) % 2 == 0 then even_sum = even_sum + 1 end
end end end
expect("triangles with even sum", count(query {
    triangle(?a, ?b, ?c), where ((?a + ?b + ?c) % 2 == 0)
}), even_sum)

-- Projection to the smallest corner: it can be any of 1 .. n-2.
expect("distinct smallest corners", count(query triangle(?a, ?_, ?_)), n - 2)

if SCALE == "small" then
    -- n = 5: triangles containing node 1 as smallest corner: C(4,2) = 6.
    expect("triangles through 1 as smallest", count(query triangle(1, ?b, ?c)), 6)
end
