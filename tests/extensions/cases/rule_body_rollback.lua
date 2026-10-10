-- Even body relations introduced before validation must roll back on failure.
relation seed(1) relation existing(1) fact seed(1)
reject(function() rule existing(?missing) :- undeclared(?x) end, "not bound")
relation undeclared(2)
assert(count(query existing(?x)) == 0 and count(query seed(?x)) == 1)
