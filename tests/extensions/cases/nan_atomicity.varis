-- Extension regression: nan_atomicity
local nan = 0 / 0
reject(function() fact fresh(nan) end, "NaN")
relation fresh(2) -- failed implicit declaration must not persist
reject(function() logic.add(logic.global, "dynamic", nan) end, "NaN")
relation dynamic(2)
relation p(1) fact p(1)
reject(function() retract p(nan) end, "NaN")
reject(function() local q = query p(nan) end, "NaN")
reject(function() rule fresh(1, 2) :- p(nan) end, "NaN")
assert(count(query p(?x)) == 1 and count(query fresh(?x, ?y)) == 0)
