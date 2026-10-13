-- Varis reference example: key order, savepoints, aggregates, and rollback.
relation balance(owner, currency, amount) key(currency, owner)
set balance(:player, :coins, 15)
relation owns(owner, item)
local discarded
transaction do
    adjust balance(:coins, :player) by -10
    fact owns(:player, :key)
    transaction do
        set balance(:player, :coins, 999)
        discarded = query balance(:player, :coins, ?amount)
        rollback
    end
    assert((query balance(:player, :coins, ?amount))().amount == 5)
end
assert((query owns(:player, :key))() ~= nil)
assert(not pcall(discarded))

relation person(1)
relation bonus(person, item, amount)
fact person(:player)
fact bonus(:player, :ring, 2)
fact bonus(:player, :hat, 2)
rule total(?person, ?amount) :- person(?person),
    ?amount = sum { ?bonus : bonus(?person, ?item, ?bonus) }
assert((query total(:player, ?amount))().amount == 4)

local ok = pcall(function()
    transaction do
        delete balance(:coins, :player)
        error("cancel")
    end
end)
assert(not ok)
assert((query balance(:player, :coins, ?amount))().amount == 5)
print("state: ok")
