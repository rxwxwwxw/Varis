-- Extension regression: runtime_registration
relation seed(1) relation out(2) fact seed(1)
local function install(tag)
    rule out(tag, ?x) :- seed(?x)
end
assert(count(query out(?tag, ?x)) == 0)
local old = query out(?tag, ?x)
for i = 1, 20 do install(i) end
assert(count(old) == 0 and count(query out(?tag, ?x)) == 20)
fact seed(2)
assert(count(query out(?tag, ?x)) == 40)
