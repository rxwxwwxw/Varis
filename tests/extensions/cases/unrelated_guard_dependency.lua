-- Extension regression: unrelated_guard_dependency
relation safe(1) relation seed(1) relation poisoned(1)
fact safe(1) fact seed(2)
local function boom() error("UNRELATED_GUARD") end
rule poisoned(?x) :- seed(?x), where (boom())
assert(count(query safe(?x)) == 1, "query evaluated an unrelated dependency")
