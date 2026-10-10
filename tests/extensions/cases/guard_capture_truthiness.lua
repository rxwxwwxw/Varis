-- Extension regression: guard_capture_truthiness
relation seed(1) fact seed(1)
local threshold = 2
local q = query {seed(?x), where (?x < threshold)}
relation out(1)
rule out(?x) :- seed(?x), where (?x < threshold)
threshold = 0
assert(count(q) == 1 and count(query out(?x)) == 1)
local function first() return false, true end
assert(count(query {seed(?x), where (first())}) == 0)
assert(count(query {seed(?x), where (0)}) == 1)
assert(count(query {seed(?x), where ("")}) == 1)
assert(count(query {seed(?x), where (nil)}) == 0)
local box = {}
relation object(1) fact object(box)
local ref = query {object(?x), where (box == ?x)}
box = {}
assert(count(ref) == 1, "guard capture must retain the original object identity")
