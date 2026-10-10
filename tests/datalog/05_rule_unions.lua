-- Spec §6.2, §6.5, §6.6: several rules for one head are united; mutually
-- recursive rules; constants in rule heads; repeated registration.
--
-- Chain 1 -> 2 -> ... -> N.  Pairs (i, j) with i < j and distance d = j - i
-- exist N - d times.  "odd" holds for odd d, "even" for even d >= 2.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { n = 6 },
    large = { n = 70 },
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

for i = 1, N - 1 do fact edge(i, i + 1) end

-- Two rules, one head: directed edges become an undirected relation.
rule connected(?x, ?y) :- edge(?x, ?y)
rule connected(?x, ?y) :- edge(?y, ?x)
expect("undirected pairs", count(query connected(?x, ?y)), 2 * (N - 1))
expect("neighbours of 2", collect(query connected(2, ?y), "y"), "1 3")

-- Mutual recursion: odd and even path lengths defined in terms of each other.
rule odd(?x, ?y) :- edge(?x, ?y)
rule even(?x, ?z) :- odd(?x, ?y), edge(?y, ?z)
rule odd(?x, ?z) :- even(?x, ?y), edge(?y, ?z)

local want_odd, want_even = 0, 0
for d = 1, N - 1 do
    if d % 2 == 1 then want_odd = want_odd + (N - d) else want_even = want_even + (N - d) end
end
expect("odd-length pairs", count(query odd(?x, ?y)), want_odd)
expect("even-length pairs", count(query even(?x, ?y)), want_even)
expect("no pair is both", count(query { odd(?x, ?y), even(?x, ?y) }), 0)
expect("1 to 2 is odd", count(query odd(1, 2)), 1)
expect("1 to 3 is even", count(query even(1, 3)), 1)

-- Overlapping rules derive the same tuple twice; set semantics keeps one.
rule near(?x, ?y) :- edge(?x, ?y)
rule near(?x, ?y) :- connected(?x, ?y), edge(?x, ?y)
expect("duplicate derivations", count(query near(?x, ?y)), N - 1)

-- Registering an equivalent rule again changes nothing logically.
rule near(?x, ?y) :- edge(?x, ?y)
rule near(?x, ?y) :- edge(?x, ?y)
expect("rule registered repeatedly", count(query near(?x, ?y)), N - 1)

-- A head may contain a constant captured when the rule is registered.
local category = :chain
rule categorized(?x, category) :- edge(?x, ?_)
expect("categorized nodes", count(query categorized(?x, :chain)), N - 1)
expect("distinct categories", collect(query categorized(?_, ?c), "c"), "chain")
category = :changed
expect("constant is captured", count(query categorized(?x, :changed)), 0)

-- A rule registered inside a function outlives the function call.
local function register_in_function()
    rule has_successor(?x) :- edge(?x, ?_)
end
register_in_function()
expect("rule persists after function returns", count(query has_successor(?x)), N - 1)

-- Rules are registered when execution reaches them, not when the file loads.
local function extend(limit)
    rule small_node(?x) :- edge(?x, ?_), ?x <= limit
end
expect("rule absent before registration", count(query { edge(?x, ?_), ?x <= 2 }), 2)
rejects("unregistered relation unknown", function() local q = query small_node(?x) end, "unknown relation")
extend(2)
expect("rule present after registration", count(query small_node(?x)), 2)
