relation balance(entity, value) key(entity)
relation owns(2)
relation eligible(1)
fact balance(:player, 10)
rule eligible(?player) :- balance(?player, ?n), ?n >= 10, not owns(?player, :key)
local initial = query balance(:player, ?value)
local kept, lost, nested_lost
transaction do
    adjust balance(:player) by -2
    assert((query balance(:player, ?value))().value == 8)
    assert((query eligible(:player))() == nil)
    transaction do
        adjust balance(:player) by 100
        nested_lost = query balance(:player, ?value)
        rollback
        error("rollback must exit the nested block")
    end
    assert((query balance(:player, ?value))().value == 8)
    transaction do adjust balance(:player) by 1 end
    kept = query balance(:player, ?value)
end
assert(initial().value == 10)
assert(kept().value == 9)
reject(nested_lost, "invalid query iterator")
assert((query balance(:player, ?value))().value == 9)
local ok = pcall(function()
    transaction do
        set balance(:player, 50)
        fact owns(:player, :key)
        lost = query balance(:player, ?value)
        assert(lost().value == 50)
        error("abort")
    end
end)
assert(not ok)
reject(lost, "invalid query iterator")
assert((query balance(:player, ?value))().value == 9)
assert((query owns(:player, :key))() == nil)
local outer_lost
transaction do
    transaction do
        set balance(:player, 20)
        outer_lost = query balance(:player, ?value)
    end
    rollback
end
reject(outer_lost, "invalid query iterator")
assert((query balance(:player, ?value))().value == 9)
transaction do
    reject(function() fact undeclared(1) end, "schema and rule registration prohibited")
    reject(function() relation forbidden(1) end, "schema and rule registration prohibited")
    reject(function() rule eligible(?x) :- balance(?x, ?n) end, "schema and rule registration prohibited")
    reject(function() local relation forbidden(1) end, "schema and rule registration prohibited")
    reject(function() adjust balance(:player) by "bad" end, "requires numeric values")
    adjust balance(:player) by 1
end
assert((query balance(:player, ?value))().value == 10)
