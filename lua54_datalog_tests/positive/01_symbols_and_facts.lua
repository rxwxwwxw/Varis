-- PASS: symbol identity, dynamic symbol creation, and set-valued facts.
local alpha = :alpha
assert(type(alpha) == "symbol")
assert(alpha == symbol("alpha"))
assert(alpha == logic.symbol("alpha"))
assert(alpha ~= "alpha")
assert(alpha ~= :beta)
assert(logic.symbolname(alpha) == "alpha")
assert(logic.symbolname(symbol("not-an-identifier")) == "not-an-identifier")

local t = {[alpha] = "found"}
assert(t[symbol("alpha")] == "found")

relation token(1)
fact token(:alpha)
fact token(symbol("alpha")) -- duplicate fact must not add another tuple
fact token(:beta)

local seen = {}
local count = 0
for m in query token(?value) do
    assert(not seen[m.value], "query returned a duplicate")
    seen[m.value] = true
    count = count + 1
end
assert(count == 2)
assert(seen[:alpha] and seen[:beta])
print("PASS 01_symbols_and_facts")
