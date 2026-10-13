-- Extension regression: negation_mutation
relation universe(1) relation banned(1) relation allowed(1) relation denied(1)
for i = 1, 40 do fact universe(i) end
rule allowed(?x) :- universe(?x), not banned(?x)
rule denied(?x) :- universe(?x), not allowed(?x)
for round = 1, 5 do
    for i = 1, 40, 2 do fact banned(i) end
    assert(count(query allowed(?x)) == 20 and count(query denied(?x)) == 20)
    for i = 1, 40, 2 do retract banned(i) end
    assert(count(query allowed(?x)) == 40 and count(query denied(?x)) == 0)
end
fact allowed(1) fact banned(1)
assert(count(query allowed(1)) == 1)
retract allowed(1)
assert(count(query allowed(1)) == 0)
