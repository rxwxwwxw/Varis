-- Extension regression: rule_capture_constants
relation seed(1) relation out(2)
fact seed(1) fact seed(2)
local tag, wanted = :old, 1
rule out(tag, ?x) :- seed(wanted), seed(?x)
tag, wanted = :new, 99
assert(count(query out(:old, ?x)) == 2 and count(query out(:new, ?x)) == 0)
local q = query out(tag, ?x)
tag = :old
assert(count(q) == 0)
