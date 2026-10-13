-- Extension regression: world_inheritance_stress
relation seed(1) relation out(1)
fact seed(0)
rule out(?x) :- seed(?x)
local worlds = {logic.world()}
for i = 2, 24 do
    local parent = worlds[i - 1]
    worlds[i] = logic.world(parent)
    logic.add(worlds[i], "seed", i)
end
for i = 1, 24 do
    local w = worlds[i]
    assert(count(query w.out(?x)) == i)
    logic.retract(w, "seed", 0)
end
assert(count(query out(?x)) == 1)
for i = 1, 24 do
    local w = worlds[i]
    assert(count(query w.out(?x)) == i - 1)
end
