-- Spec §5.1, §7, §6.5: Lua expressions in declarations are evaluated once, at
-- the moment the fact, rule or query is built, and each contributes one value.
--
-- Benchmark: R rules are registered in a loop, rule k capturing origin k.  On
-- the chain 1 -> 2 -> ... the rule for origin k derives node k+1, so the union
-- relation `hit` holds exactly R nodes: 2 .. R+1.
local SCALE = (arg and arg[1]) or "small"
local P = ({
    small = { rules = 3 },
    large = { rules = 1500 },
})[SCALE] or error("unknown scale: " .. tostring(SCALE))
local R = P.rules

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

local evaluations = 0
local function counted(v)
    evaluations = evaluations + 1
    return v
end

-- A fact argument is evaluated once per execution of the statement.
fact num(counted(1))
expect("fact evaluates once", evaluations, 1)
for i = 1, 3 do fact num(counted(i + 1)) end
expect("loop executes the statement 3 times", evaluations, 4)

-- A rule's constants are evaluated at registration, not per tuple or per query.
evaluations = 0
fact edge(1, 2) fact edge(2, 3) fact edge(3, 4)
rule from_two(?y) :- edge(counted(2), ?y)
expect("rule evaluates constant once", evaluations, 1)
expect("rule result", collect(query from_two(?y), "y"), "3")
expect("querying does not re-evaluate", evaluations, 1)

-- A query evaluates its constants when constructed, not when iterated.
evaluations = 0
local q = query edge(counted(1), ?y)
expect("query evaluates at construction", evaluations, 1)
count(q)
expect("iteration does not re-evaluate", evaluations, 1)

-- The captured constant is the value at that moment.
local room = 1
local early = query edge(room, ?y)
room = 3
expect("query captured room=1", collect(early, "y"), "2")
expect("new query sees room=3", collect(query edge(room, ?y), "y"), "4")

-- A function that registers a rule captures its argument per invocation.
local function add_origin_rule(origin)
    rule from_origin(?x) :- edge(origin, ?x)
end
add_origin_rule(1)
add_origin_rule(3)
expect("one rule per invocation", collect(query from_origin(?x), "x"), "2 4")

-- A call with several results contributes only its first result.
local function pair() return 2, 99 end
expect("multi-result in query", collect(query edge(pair(), ?y), "y"), "3")
fact first_only(pair())
expect("multi-result in fact", collect(query first_only(?v), "v"), "2")
rejects("final call is not expanded", function() fact edge(pair()) end, "expects arity 2")

-- Constants are values, not names: later assignment to the variable that
-- supplied a rule's constant does not change the registered rule.
local target = 4
rule into_target(?x) :- edge(?x, target)
target = 2
expect("rule kept target=4", collect(query into_target(?x), "x"), "3")

-- NaN is not a valid relational constant, wherever it comes from.
rejects("NaN fact", function() fact edge(0/0, 1) end, "NaN")
rejects("NaN query constant", function() local z = query edge(0/0, ?y) end, "NaN")
rejects("NaN rule constant", function()
    local nan = 0/0
    rule bad(?y) :- edge(nan, ?y)
end, "NaN")

-- Benchmark: R rules, each capturing a different origin.
for k = 1, R do fact chain(k, k + 1) end
for k = 1, R do
    local origin = k
    rule hit(?x) :- chain(origin, ?x)
end
expect("union of captured origins", count(query hit(?x)), R)
expect("smallest hit", count(query hit(2)), 1)
expect("largest hit", count(query hit(R + 1)), 1)
expect("origin itself not hit", count(query hit(1)), 0)
