-- Extension regression: raw_identity
local calls = 0
local mt = {__eq = function() calls = calls + 1; return true end}
local a, b = setmetatable({}, mt), setmetatable({}, mt)
local f, g = function() end, function() end
local co = coroutine.create(function() end)
relation object(1)
fact object(a) fact object(a) fact object(b)
fact object(f) fact object(g) fact object(co)
assert(count(query object(?v)) == 5)
assert(count(query object(a)) == 1)
retract object(a)
assert(count(query object(a)) == 0 and count(query object(b)) == 1)
assert(calls == 0, "relational equality invoked __eq")
