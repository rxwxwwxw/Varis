-- Spec §4, §5: relations, arity, set semantics, fact/retract as executed statements.
--
-- Every `expect(label, got, want)` asserts and prints "label<TAB>got".
-- Benchmark: N insertions of which only K are distinct, then N distinct pairs,
-- then retraction of every other pair.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { inserts = 12,    distinct = 5 },
    large = { inserts = 60000, distinct = 700 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))

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

-- Declaring twice with the same arity is harmless; a different arity is an error.
relation edge(2)
relation edge(2)
rejects("redeclare with other arity", function() relation edge(3) end, "already declared")

-- A relation is also established by its first fact, and arity is then enforced.
fact color(:red)
expect("implicit relation size", count(query color(?c)), 1)
rejects("fact with too few arguments", function() fact edge(:a) end, "expects arity 2")
rejects("fact with too many arguments", function() fact color(:a, :b) end, "expects arity 1")

-- Set semantics: inserting the same tuple again changes nothing.
fact edge(:a, :b)
fact edge(:a, :b)
expect("duplicate fact stored once", count(query edge(?x, ?y)), 1)

-- Retracting something absent is not an error.
retract edge(:x, :y)
expect("retract absent tuple", count(query edge(?x, ?y)), 1)
retract edge(:a, :b)
expect("retract present tuple", count(query edge(?x, ?y)), 0)

-- Declared relations with no tuples may be queried (zero results, no error).
-- An undeclared one may not.
expect("empty declared relation", count(query edge(?x, ?y)), 0)
rejects("unknown relation", function() local q = query nowhere(?x) end, "unknown relation")

-- Tuples compare by raw Lua equality: 1 and 1.0 are the same number,
-- a string is not a symbol, and two distinct tables are two values.
fact num(1)
fact num(1.0)
expect("1 and 1.0 are one tuple", count(query num(?n)), 1)
fact name("a")
fact name(:a)
expect("string and symbol differ", count(query name(?n)), 2)
local t1, t2 = {}, {}
fact obj(t1) fact obj(t1) fact obj(t2)
expect("tables compare by identity", count(query obj(?o)), 2)
fact maybe(nil)
fact maybe(false)
expect("nil and false are values", count(query maybe(?v)), 2)

-- Facts are executed statements: loops and conditionals decide what is inserted.
for i = 1, 10 do
    if i % 2 == 0 then fact even_number(i) end
end
expect("loop-inserted facts", count(query even_number(?n)), 5)

-- Each argument contributes exactly one value, even for multi-result calls.
local function two() return :left, :right end
fact single(two())
expect("call truncated to one value", (query single(?v))().v, :left)
rejects("call is not expanded", function() fact edge(two()) end, "expects arity 2")

-- Zero-arity relations hold at most the empty tuple.
fact ready()
fact ready()
expect("zero-arity relation", count(query ready()), 1)

-- Benchmark.  inserts i = 1..N map onto K values: expect exactly K tuples.
for i = 1, P.inserts do
    fact slot(i % P.distinct)
end
expect("distinct slots", count(query slot(?s)), P.distinct)

-- N distinct pairs, then retract the pairs with even i.
for i = 1, P.inserts do
    fact pair(i, i % 7)
end
expect("pairs", count(query pair(?i, ?r)), P.inserts)
for i = 2, P.inserts, 2 do
    retract pair(i, i % 7)
end
expect("pairs after retracting evens", count(query pair(?i, ?r)), P.inserts // 2)
expect("pair lookup of an odd i", count(query pair(3, ?r)), 1)
expect("pair lookup of an even i", count(query pair(4, ?r)), 0)
