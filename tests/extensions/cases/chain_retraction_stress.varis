-- Extension regression: chain_retraction_stress
relation edge(2) relation reach(2)
for i = 1, 64 do fact edge(i, i + 1) end
rule reach(?x, ?y) :- edge(?x, ?y)
rule reach(?x, ?y) :- edge(?x, ?z), reach(?z, ?y)
assert(count(query reach(1, ?y)) == 64)
local old = query reach(1, ?y)
retract edge(32, 33)
assert(count(query reach(1, ?y)) == 31 and count(old) == 64)
fact edge(32, 33) fact edge(65, 1)
assert(count(query reach(?x, ?y)) == 65 * 65)
