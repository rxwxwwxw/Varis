-- Extension regression: guard_yield_restore
relation seed(1) fact seed(1)
local function helper() coroutine.yield("forbidden"); return true end
local co = coroutine.create(function()
    local q = query {seed(?x), where (helper())}
    reject(function() q() end, "yield")
    reject(function() q() end, "invalid query iterator")
    coroutine.yield("restored")
    return count(query seed(?x))
end)
local ok, v = coroutine.resume(co)
assert(ok and v == "restored", "guard yield escaped or yieldability was not restored")
ok, v = coroutine.resume(co)
assert(ok and v == 1 and coroutine.status(co) == "dead")

local child = coroutine.create(function()
    assert(not coroutine.isyieldable())
    coroutine.yield("must not escape inference")
end)
local function indirect()
    local ok, err = coroutine.resume(child)
    assert(not ok and string.find(err, "yield"))
    return true
end
assert(count(query {seed(?x), where (indirect())}) == 1)
local later = coroutine.create(function()
    assert(coroutine.isyieldable())
    coroutine.yield("restored child")
end)
local ok, value = coroutine.resume(later)
assert(ok and value == "restored child")
