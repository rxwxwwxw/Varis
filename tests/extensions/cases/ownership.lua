-- Extension regression: ownership
local other = logic.emptyworld()
fact other.source(1)
relation source(1) relation dest(1) fact source(2)
reject(function() rule dest(?x) :- other.source(?x) end, "cross-world")
do
    local relation hidden(1) fact hidden(3)
    reject(function() rule dest(?x) :- hidden(?x) end, "local relation")
end
assert(count(query dest(?x)) == 0)
rule dest(?x) :- source(?x)
assert((query dest(?x))().x == 2)
