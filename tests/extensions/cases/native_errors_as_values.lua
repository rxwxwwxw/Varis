-- Errors a native function reports as a value (performance plan, stage L1; the math library is
-- the first converted module) look exactly like thrown ones: the same message, position, name of
-- the function taken from the call site, traceback, and behaviour under pcall, xpcall,
-- coroutines, metamethods, to-be-closed variables, transactions and deep recursion.
local function msg(f, ...)
    local ok, e = pcall(f, ...)
    assert(not ok)
    return (tostring(e):gsub("^[^:]*:%d+: ", "@: "))
end

assert(msg(math.floor, "x") == "bad argument #1 to 'math.floor' (number expected, got string)")
assert(msg(function() return math.floor("x") end) == "@: bad argument #1 to 'floor' (number expected, got string)")
assert(msg(function() local v = math.floor({}) return v end) == "@: bad argument #1 to 'floor' (number expected, got table)")
assert(msg(function() local t = {m = math.floor} return t:m() end) == "@: calling 'm' on bad self (number expected, got table)")
assert(msg(function() local g = math.sqrt local v = g() return v end) == "@: bad argument #1 to 'g' (number expected, got no value)")
assert(msg(math.fmod, 1, 0) == "bad argument #2 to 'math.fmod' (zero)")
assert(msg(math.random, 2, 1) == "bad argument #1 to 'math.random' (interval is empty)")
assert(msg(math.random, 1, 2, 3) == "wrong number of arguments")
assert(msg(math.ult, 1.5, 2) == "bad argument #1 to 'math.ult' (number has no integer representation)")
assert(msg(math.atan, 1, {}) == "bad argument #2 to 'math.atan' (number expected, got table)")
assert(msg(math.min) == "bad argument #1 to 'math.min' (number expected, got no value)"
    or msg(math.min) == "bad argument #1 to 'math.min' (value expected)")
assert(msg(math.type) == "bad argument #1 to 'math.type' (value expected)")

-- the position is the calling line
local line = debug.getinfo(1, "l").currentline + 1
local _, located = pcall(function() local v = math.exp("e") return v end)
assert(located:find(":" .. line .. ": bad argument", 1, true), located)

-- traceback names the native and the frames below it
local trace = select(2, xpcall(function() local v = math.floor("t") return v end, debug.traceback))
assert(trace:find("[C]: in function 'math.floor'", 1, true) and trace:find("[C]: in function 'xpcall'", 1, true), trace)

-- a coroutine dies with the error and keeps its traceback; wrap rethrows it
local co = coroutine.create(function() local v = math.log({}) return v end)
local ok, e = coroutine.resume(co)
assert(not ok and e:find("bad argument #1 to 'log'", 1, true) and coroutine.status(co) == "dead")
assert(debug.traceback(co):find("in function 'math.log'", 1, true))
assert(msg(function() return coroutine.wrap(function() local v = math.ceil("c") return v end)() end)
    :find("bad argument #1 to 'ceil'", 1, true))

-- raised inside a metamethod, an iterator and a sort callback
local object = setmetatable({}, {__index = function() local v = math.rad("m") return v end})
assert(msg(function() return object.field end):find("bad argument #1 to 'rad'", 1, true))
assert(msg(function() for _ in function() local v = math.deg({}) return v end do end end):find("to 'deg'", 1, true))
assert(msg(function() table.sort({2, 1}, function(a, b) local v = math.abs("s") return a < b end) end):find("to 'abs'", 1, true))

-- to-be-closed variables are closed with the error, and a transaction is rolled back
local closedWith
relation kept(x)
assert(msg(function()
    transaction do
        local guard <close> = setmetatable({}, {__close = function(_, err) closedWith = err end})
        fact kept(1)
        local v = math.modf("z")
    end
end):find("to 'modf'", 1, true))
assert(tostring(closedWith):find("to 'modf'", 1, true))
assert((query { kept(1) })() == nil)

-- past the depth where calls stop recursing natively, and in a tail call there
local function deep(n) if n == 0 then local v = math.sqrt("deep") return v end return (deep(n - 1)) end
assert(msg(deep, 400) == "@: bad argument #1 to 'sqrt' (number expected, got string)")
local function deepTail(n) if n == 0 then return math.tan({}) end return (deepTail(n - 1)) end
assert(msg(deepTail, 400):find("bad argument #1 to 'tan' (number expected, got table)", 1, true))

-- error handlers see the same object; successful calls are unaffected in between
local seen
assert(not xpcall(function() local v = math.acos("h") end, function(err) seen = err return err end))
assert(seen:find("to 'acos'", 1, true))
assert(math.floor(2.5) == 2 and math.max(1, 5, 3) == 5 and math.tointeger("8") == 8 and math.fmod(7, 3) == 1)
print("ok")
