-- Extension regression: contextual_syntax
local fact, retract, rule, relation, query, where = 1, 2, 3, 4, 5, 6
assert(fact + retract + rule + relation + query + where == 21)
local t = {fact = function(self, x) return x end, query = 9}
assert(t:fact(7) == 7 and t.query == 9)
local function query(x) return x + 1 end
assert(query(4) == 5)
relation p(1)
local p = 99 -- ordinary local does not shadow the relation namespace
fact p(:ok)
assert((query p(?x))().x == :ok)
