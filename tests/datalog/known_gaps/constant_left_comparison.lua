-- KNOWN-GAP: unexpected symbol
-- Spec §17.6: comparison ::= term compareop term, and a term may be an exp,
-- so a Lua constant may stand on the LEFT of a comparison in a query body.
-- dlua only accepts a logic variable as the first operand and reports a
-- syntax error; load() lets the program capture that diagnostic.
-- This program prints "GAP CLOSED" once the construct is accepted.
fact num(1) fact num(5)
local chunk, err = load("local limit = 3 local n = 0 for _ in query { num(?a), limit < ?a } do n = n + 1 end return n")
assert(chunk, err)
assert(chunk() == 1, "expected one number above 3")
print("GAP CLOSED")
