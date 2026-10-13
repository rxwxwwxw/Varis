-- Spec §12: query iterators, snapshots, projection, binding records.
--
-- Benchmark: N iterators are created over N facts; then every fact is
-- retracted and the iterators are drained.  Each must still deliver its
-- snapshot: iterator i was created when facts 1..N existed.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { n = 4 },
    large = { n = 800 },
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

fact edge(:a, :b)
fact edge(:a, :c)
fact edge(:b, :c)

-- A query is a callable iterator; an exhausted one keeps returning nil.
local it = query edge(:b, ?to)
local first = it()
expect("first result", first.to, :c)
expect("then exhausted", it(), nil)
expect("still exhausted", it(), nil)

-- Every query expression builds a new, independent iterator.
local one, two = query edge(:a, ?to), query edge(:a, ?to)
expect("independent iterators", count(one) + count(two), 4)

-- Snapshot: facts added after construction are not seen by that iterator.
local before = query edge(?x, ?y)
fact edge(:c, :d)
expect("snapshot ignores new fact", count(before), 3)
expect("new query sees new fact", count(query edge(?x, ?y)), 4)

-- Projection is a set: edge(:a, ?_) has two matches but one distinct row.
expect("anonymous variable gives one row", count(query edge(:a, ?_)), 1)
expect("projection on source only", collect(query edge(?from, ?_), "from"), "a b c")
-- The record omits anonymous variables and repeats a variable only once.
local rec = (query edge(?x, ?_))()
expect("anonymous variable omitted", logic.hasbinding(rec, "_"), false)
fact loop(:s, :s)
fact loop(:s, :t)
expect("repeated variable matches only equal", count(query loop(?v, ?v)), 1)
expect("repeated variable one field", (query loop(?v, ?v))().v, :s)

-- A ground query yields one empty record on success and nothing on failure.
expect("ground success", count(query edge(:a, :b)), 1)
expect("ground failure", count(query edge(:b, :a)), 0)

-- Conjunctive query: a two-step path that does not end in :d.
expect("two-step paths", collect(query {
    edge(:a, ?mid), edge(?mid, ?last), ?last ~= :d
}, "last"), "c")

-- Binding records: field access, hasbinding/binding, nil bindings, immutable.
fact slot(:k, nil)
local r = (query slot(:k, ?v))()
expect("nil binding reads as nil", r.v, nil)
expect("nil binding is present", logic.hasbinding(r, "v"), true)
expect("binding() on nil binding", logic.binding(r, "v"), nil)
expect("absent name", logic.hasbinding(r, "nope"), false)
expect("absent field reads as nil", r.nope, nil)
rejects("binding() of absent name", function() return logic.binding(r, "nope") end, "not found")
rejects("records are immutable", function() r.v = 1 end, "immutable")

-- Benchmark.
for i = 1, N do fact item(i) end
local iterators = {}
for i = 1, N do iterators[i] = query item(?n) end
for i = 1, N do retract item(i) end
expect("live relation is empty", count(query item(?n)), 0)
local total = 0
for i = 1, N do total = total + count(iterators[i]) end
expect("snapshots delivered", total, N * N)
