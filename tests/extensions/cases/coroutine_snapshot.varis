-- Extension regression: coroutine_snapshot
relation p(1) fact p(1)
local co = coroutine.create(function()
    local q = query p(?x)
    coroutine.yield("frozen")
    assert(q().x == 1 and q() == nil)
    return (query p(?x))().x
end)
local ok, v = coroutine.resume(co) assert(ok and v == "frozen")
retract p(1) fact p(2)
ok, v = coroutine.resume(co) assert(ok and v == 2)
