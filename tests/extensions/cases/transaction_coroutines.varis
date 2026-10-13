relation counter(entity, n) key(entity)
fact counter(:p, 1)
local observer = coroutine.create(function()
    assert((query counter(:p, ?n))().n == 1)
    reject(function() set counter(:p, 99) end, "locked by another transaction")
    reject(function() transaction do end end, "locked by another transaction")
    assert(not coroutine.isyieldable())
    reject(function() coroutine.yield("forbidden child") end, "attempt to yield")
    return "committed only"
end)
local worker = coroutine.create(function()
    assert(coroutine.isyieldable())
    transaction do
        assert(not coroutine.isyieldable())
        adjust counter(:p) by 1
        local ok, message = coroutine.resume(observer)
        assert(ok and message == "committed only")
        reject(function() coroutine.yield("forbidden") end, "attempt to yield")
    end
    assert(coroutine.isyieldable())
    assert(not pcall(function()
        transaction do
            adjust counter(:p) by 100
            coroutine.yield("forbidden")
        end
    end))
    assert(coroutine.isyieldable())
    return (query counter(:p, ?n))().n
end)
local ok, value = coroutine.resume(worker)
assert(ok and value == 2)
local later = coroutine.create(function()
    assert(coroutine.isyieldable())
    coroutine.yield("restored")
end)
local observed, number = coroutine.resume(later)
assert(observed and number == "restored")
