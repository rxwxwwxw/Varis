-- Extension regression: numeric_infinities
relation p(1)
local inf = math.huge
fact p(inf) fact p(-inf) fact p(inf) fact p(0) fact p(-0.0)
assert(count(query p(?x)) == 3)
assert(count(query p(inf)) == 1 and count(query p(-inf)) == 1)
retract p(-0.0)
assert(count(query p(0)) == 0 and count(query p(?x)) == 2)
