-- Extension regression: constant_single_evaluation
local calls = 0
local function many() calls = calls + 1; return 7, 8, 9 end
relation p(2)
fact p(many(), many())
assert(calls == 2 and count(query p(7, 7)) == 1)
local q = query p(many(), ?x)
assert(calls == 3 and q().x == 7 and calls == 3)
relation derived(1)
rule derived(many()) :- p(many(), ?x)
assert(calls == 5 and count(query derived(7)) == 1 and calls == 5)
local function variadic(...)
    fact p(6, ...)
end
variadic(4, 5)
assert(count(query p(6, 4)) == 1)
