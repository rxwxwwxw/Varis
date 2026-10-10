relation person(1)
relation item(3)
relation total(2)
fact person(:alice)
fact person(:bob)
fact item(:alice, :a, 5)
fact item(:alice, :b, 5)
fact item(:alice, :c, 7)
rule total(?person, ?total) :- person(?person), ?total = sum { ?bonus : item(?person, ?item, ?bonus) }
assert((query total(:alice, ?n))().n == 17)
assert((query total(:bob, ?n))().n == 0)
local record = (query {person(?p), ?n = count {item(?p, ?item, ?bonus)}})()
assert(record.p ~= nil and record.item == nil and record.bonus == nil)
assert((query {?n = count {item(:alice, ?_, ?_)}})().n == 3)
assert((query {?n = min {?bonus : item(:alice, ?i, ?bonus)}})().n == 5)
assert((query {?n = max {?bonus : item(:alice, ?i, ?bonus)}})().n == 7)
assert((query {?n = min {?bonus : item(:bob, ?i, ?bonus)}})() == nil)
assert((query {?n = count {item(:bob, ?i, ?bonus)}})().n == 0)
assert((query {?n = sum {?bonus * 2 : item(:alice, ?i, ?bonus)}, ?n > 30})().n == 34)
local before = query total(:alice, ?n)
transaction do
    retract item(:alice, :a, 5)
    assert((query total(:alice, ?n))().n == 12)
    rollback
end
assert(before().n == 17)
local child = logic.world()
retract child.item(:alice, :a, 5)
assert((query child.total(:alice, ?n))().n == 12)
assert((query total(:alice, ?n))().n == 17)
reject(function()
    rule unsafe(?n) :- ?n = sum {?x : person(:alice)}
end, "aggregate expression variable")
reject(function()
    rule cycle(?n) :- ?n = count {cycle(?x)}
end, "aggregate cycle")
reject(function()
    rule same(?p) :- person(?p), ?p = count {item(?p, ?i, ?b)}
end, "must be newly bound")
reject(function()
    local iterator = query {?n = sum {:symbol : item(:alice, ?i, ?b)}}
    iterator()
end, "requires numeric values")
local lexical = 3
local frozen = query {?n = sum {?bonus * lexical : item(:alice, ?i, ?bonus)}}
lexical = 4
assert(frozen().n == 51)
-- Nested aggregation and a preceding aggregate's correlated output.
assert((query {?n = count {person(?p), ?s = sum {?b : item(?p, ?i, ?b)}, ?s > 0}})().n == 1)

local calculator = {multiply = function(self, n) return n * 2 end}
local function identity(n) return n end
assert((query {?n = sum {calculator:multiply(?bonus) : item(:alice, ?i, ?bonus)}})().n == 34)
assert((query {?n = sum {identity(calculator:multiply(?bonus)) : item(:alice, ?i, ?bonus)}})().n == 34)

relation large(1)
fact large(9007199254740992.0)
fact large(9007199254740993)
assert((query {?n = max {?x : large(?x)}})().n == 9007199254740993)
assert((query {?n = min {?x : large(?x)}})().n == 9007199254740992.0)
assert(9007199254740992.0 < 9007199254740993)
assert(not (9007199254740993 <= 9007199254740992.0))
