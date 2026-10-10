relation value(entity, n) key(entity)
fact value(:p, 1)
local other = logic.world()
transaction do
    reject(function() set other.value(:p, 10) end, "cross-world mutation")
    reject(function() transaction (other) do end end, "same world")
    reject(function() logic.add(other, "value", :q, 2) end, "cross-world mutation")
    reject(function() logic.retract(other, "absent", 1) end, "cross-world mutation")
end
local selections = 0
local function choose_world() selections = selections + 1; return other end
transaction (choose_world()) do set value(:p, 3) end
assert(selections == 1)
assert((query other.value(:p, ?n))().n == 3)
assert((query value(:p, ?n))().n == 1)
local function returning()
    transaction do set value(:p, 4); return 42 end
end
assert(returning() == 42)
assert((query value(:p, ?n))().n == 4)
for i = 1, 3 do
    transaction do set value(:p, 5); break end
end
assert((query value(:p, ?n))().n == 5)
-- Break from an inner loop stays within the transaction.
transaction do
    for i = 1, 3 do set value(:p, 6); break end
    assert((query value(:p, ?n))().n == 6)
    rollback
end
assert((query value(:p, ?n))().n == 5)
local relation local_values(1)
transaction do reject(function() fact local_values(1) end, "local relation mutation prohibited") end
-- Escaped lexical-world captures must close before register reuse after break.
local captured
for i = 1, 2 do
    transaction (other) do
        captured = function() return (query value(:p, ?n))().n end
        set value(:p, 7)
        break
    end
end
do local reused = logic.global end
assert(captured() == 7)
assert((query value(:p, ?n))().n == 5)
-- Lua object mutations survive rollback; relational changes do not.
local external = { value = 0 }
transaction do
    external.value = 1
    set value(:p, 99)
    rollback
end
assert(external.value == 1 and (query value(:p, ?n))().n == 5)
