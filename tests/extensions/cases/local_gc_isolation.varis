-- Extension regression: local_gc_isolation
relation seed(1) fact seed(1)
local function factory(tag)
    local relation a(2) local relation b(2)
    rule a(tag, ?x) :- seed(?x)
    rule b(?t, ?x) :- a(?t, ?x)
    rule a(?t, ?x) :- b(?t, ?x)
    return function() return query b(?t, ?x) end
end
local f, g = factory(:first), factory(:second)
if type(collectgarbage) == "function" then
    collectgarbage("collect")
else
    print("[SKIP] forced GC: collectgarbage is unavailable; still testing escaped local closures")
end
local q = f()
fact seed(2)
assert(count(q) == 1)
for row in f() do assert(row.t == :first) end
for row in g() do assert(row.t == :second) end
assert(count(f()) == 2 and count(g()) == 2)
