-- Extension regression: query_safety_order
relation p(1) relation banned(1)
fact p(1) fact p(2) fact banned(2)
assert(count(query {not banned(?x), p(?x)}) == 1)
assert(count(query {?x == 1, p(?x)}) == 1)
assert(count(query {where (?x == 1), p(?x)}) == 1)
