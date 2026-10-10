-- KNOWN-GAP: anonymous variable
-- Spec §3.4: anonymous variables cannot appear in rule heads, procedural
-- guards, or relational constraints (comparisons).  varis rejects them in heads
-- and guards (see tests/extensions) but accepts them silently in a comparison.
fact num(1)
local ok, err = pcall(function()
    rule bad(?a) :- num(?a), ?a == ?_
end)
assert(not ok, "anonymous variable in a comparison was accepted")
assert(string.find(tostring(err), "anonymous variable", 1, true), tostring(err))
print("GAP CLOSED")
