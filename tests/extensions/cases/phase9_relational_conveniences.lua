-- Milestone 28: computed bindings (`?x := expression`), parenthesized `or` alternatives,
-- `exists { goals }` and `logic.one`.
relation item(2)
relation tag(2)
fact item(:sword, 7)
fact item(:shield, 4)
fact item(:lamp, 1)
fact tag(:sword, :weapon)
fact tag(:lamp, :light)

-- computed binding in a query: positive joins first, then the binding, then filters
local r = (query {item(:sword, ?n), ?double := ?n * 2, ?double > 10})()
assert(r.double == 14 and r.n == 7)
assert((query {item(:sword, ?n), ?double := ?n * 2, ?double > 20})() == nil)
-- bindings are ordered with aggregates and see earlier ones
local chain = (query {item(:sword, ?n), ?a := ?n + 1, ?b := ?a * 10, ?total = sum {?v : item(?i, ?v)}, ?c := ?b + ?total})()
assert(chain.a == 8 and chain.b == 80 and chain.total == 12 and chain.c == 92)
-- a binding may be any value, including strings and symbols and nil
local label = (query {item(:lamp, ?n), ?name := "lamp:" .. ?n, ?s := :found, ?z := nil})()
assert(label.name == "lamp:1" and label.s == :found and logic.hasbinding(label, "z") and label.z == nil)
-- in a rule head
relation price(2)
rule price(?i, ?p) :- item(?i, ?n), ?p := ?n * 100
assert((query price(:shield, ?p))().p == 400)
-- uses the later binding only after it exists
reject(function()
    local q = query {?a := ?b + 1, ?b := 2}
    q()
end, "not grounded")
-- must be newly bound
reject(function()
    rule bad(?n) :- item(?i, ?n), ?n := 3
end, "newly bound")
-- a recursive rule may not compute new values from itself
reject(function()
    relation count_up(1)
    fact count_up(0)
    rule count_up(?next) :- count_up(?n), ?next := ?n + 1
end, "recursive rule cycle")
-- NaN never reaches a binding
reject(function() (query {item(:lamp, ?n), ?x := 0/0})() end, "NaN")

-- alternatives
local both = {}
for rec in query {item(?i, ?n), (?n > 5 or ?n < 2)} do both[#both + 1] = rec.i end
assert(#both == 2)
assert(count(query {item(?i, ?n), (?n == 7 or ?n == 4 or ?n == 100)}) == 2)
-- left to right with short circuit: the right alternative is not evaluated once the left holds
local calls = 0
local function probe(n) calls = calls + 1; return n > 0 end
count(query {item(:sword, ?n), (?n > 0 or probe(?n))})
assert(calls == 0)
-- a parenthesized group without `or` is not an alternatives group
assert(count(query {item(?i, ?n), ?n > (1 + 1)}) == 2)

-- exists
assert(exists { item(:sword, ?n), ?n > 5 } == true)
assert(exists { item(:sword, ?n), ?n > 50 } == false)
assert(exists { item(:sword, 7) })
assert(not exists { tag(:shield, ?t) })
local function exists_in_if()
    if exists { tag(?i, :light) } then return "yes" end
    return "no"
end
assert(exists_in_if() == "yes")
-- bindings stay inside
local n = 4
assert(exists { item(?i, ?n2), ?n2 == n })

-- logic.one
assert(logic.one(query tag(:sword, ?t)).t == :weapon)
assert(logic.one(query tag(:shield, ?t)) == nil)
reject(function() logic.one(query item(?i, ?n)) end, "more than one")
reject(function() logic.one(5) end, "query expected")
