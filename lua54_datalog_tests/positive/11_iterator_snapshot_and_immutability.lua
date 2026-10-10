-- PASS: snapshot at query creation; callable iterators; immutable bindings.
relation edge(2)
fact edge(:a, :b)

local old = query edge(:a, ?target)
fact edge(:a, :c)
retract edge(:a, :b)

local first = old()
assert(first and first.target == :b)
assert(old() == nil)
assert(old() == nil)

local updated = query edge(:a, ?target)
local second = updated()
assert(second and second.target == :c)
assert(updated() == nil)

local ok = pcall(function()
    second.target = :modified
end)
assert(not ok, "query binding records must be immutable")
print("PASS 11_iterator_snapshot_and_immutability")
