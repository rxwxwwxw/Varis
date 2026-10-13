-- Extension regression: guard_errors_lazy
relation seed(1) fact seed(1)
local function boom() error("GUARD_SENTINEL") end
local q = query {seed(?x), where (boom())}
-- Construction succeeds: inference must be deferred.
reject(function() q() end, "GUARD_SENTINEL")
reject(function() q() end, "invalid query iterator")
assert(count(query seed(?x)) == 1)
