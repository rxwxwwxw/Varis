-- Spec §12.2, §12.8, §18.6: braced queries joining several relations.
--
-- A small organisation: people 1..P.  Person i works at the laboratory when i
-- is even (otherwise the office), knows person i+1, and is retired when i is a
-- multiple of 5.  The query
--     person(?p), works_at(?p, :laboratory), knows(?p, ?c), not retired(?c)
-- therefore matches every even p < P whose colleague p+1 is not a multiple of 5.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { people = 10 },
    large = { people = 3000 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local N = P.people

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
    fact person(i)
    fact works_at(i, i % 2 == 0 and :laboratory or :office)
    if i < N then fact knows(i, i + 1) end
    if i % 5 == 0 then fact retired(i) end
end

local want = 0
for p = 2, N - 1, 2 do
    if (p + 1) % 5 ~= 0 then want = want + 1 end
end

local found = 0
for m in query {
    person(?person),
    works_at(?person, :laboratory),
    knows(?person, ?colleague),
    not retired(?colleague)
} do
    assert(m.person % 2 == 0 and m.colleague == m.person + 1)
    found = found + 1
end
expect("lab workers with active colleague", found, want)

-- Small enough to check by hand: people 1..10, p in {2,4,6,8}; p=4 has
-- colleague 5 (retired), the others have colleagues 3, 7, 9.
if SCALE == "small" then
    expect("matching people", collect(query {
        person(?p), works_at(?p, :laboratory), knows(?p, ?c), not retired(?c)
    }, "p"), "2 6 8")
end

-- Projection: only distinct values of the *named* variables are returned,
-- so the N rows of works_at collapse to the two places of work.
expect("distinct places of work", count(query works_at(?_, ?place)), 2)

-- Three-way chain join: acquaintance two steps away.
local two_steps = 0
for _ in query { knows(?a, ?b), knows(?b, ?c) } do two_steps = two_steps + 1 end
expect("two-step acquaintances", two_steps, N - 2)

-- Comparison and guard in one body.
expect("a < 4 and odd", collect(query {
    person(?a), ?a < 4, where (?a % 2 == 1)
}, "a"), "1 3")

-- A conjunction that cannot hold gives no rows; one with no variables
-- returns one empty record.
expect("impossible conjunction", count(query { person(?a), ?a < 0 }), 0)
expect("ground conjunction", count(query { person(1), works_at(1, :office) }), 1)
