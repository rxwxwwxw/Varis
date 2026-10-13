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

-- the table library is converted as well, including errors found deep inside a sort
assert(msg(table.insert, {1, 2, 3}, 5, "x") == "bad argument #2 to 'table.insert' (position out of bounds)")
assert(msg(table.insert, {1}, 1, 2, 3) == "wrong number of arguments to 'insert'")
assert(msg(table.remove, {1, 2, 3}, 7) == "bad argument #2 to 'table.remove' (position out of bounds)")
assert(msg(table.concat, {1, {}, 3}) == "invalid value (table) at index 2 in table for 'concat'")
assert(msg(table.concat, 5) == "bad argument #1 to 'table.concat' (table expected, got number)")
assert(msg(table.unpack, {}, 1, 1e7) == "too many results to unpack")
assert(msg(table.move, {1, 2, 3}, 1, math.maxinteger, 2) == "bad argument #4 to 'table.move' (destination wrap around)")
assert(msg(table.sort, {3, 1, 2}, 5) == "bad argument #2 to 'table.sort' (function expected, got number)")
assert(msg(function() table.sort({1, 2, 3}, 5) end) == "@: bad argument #2 to 'sort' (function expected, got number)")
assert(msg(table.insert, setmetatable({}, {__len = function() return "x" end, __index = print, __newindex = print}), 1)
    == "object length is not an integer")
local scrambled = {}
for i = 1, 300 do scrambled[i] = (i * 7919) % 300 end
assert(msg(table.sort, scrambled, function() return true end) == "invalid order function for sorting")
assert(msg(function() table.sort(scrambled, function() return true end) end) == "@: invalid order function for sorting")
-- an error thrown by code the library calls still passes through it
assert(msg(table.sort, {3, 1, 2}, function() error("from the comparator", 0) end) == "from the comparator")
local t = {5, 3, 9}
table.sort(t, function(a, b) return a > b end)
assert(table.concat(t, ",") == "9,5,3" and table.remove(t) == 3 and select("#", table.unpack(t)) == 2)

-- the base library: assert, error and the argument checks of the rest
assert(msg(function() assert(false, "asserted") end) == "@: asserted")
assert(msg(function() assert(nil) end) == "@: assertion failed!")
assert(msg(assert) == "bad argument #1 to 'assert' (value expected)")
assert(msg(function() error("raised") end) == "@: raised")
assert(msg(error, "plain") == "plain" and msg(error, "x", {}) == "bad argument #2 to 'error' (number expected, got table)")
local payload = {}
assert(select(2, pcall(function() assert(false, payload) end)) == payload)
assert(msg(setmetatable, 1, {}) == "bad argument #1 to 'setmetatable' (table expected, got number)")
assert(msg(setmetatable, {}, 5) == "bad argument #2 to 'setmetatable' (nil or table expected, got number)")
assert(msg(setmetatable, setmetatable({}, {__metatable = 1}), {}) == "cannot change a protected metatable")
assert(msg(tonumber, "ff", 99) == "bad argument #2 to 'tonumber' (base out of range)")
assert(msg(select, 0) == "bad argument #1 to 'select' (index out of range)")
assert(msg(collectgarbage, "bogus") == "bad argument #1 to 'collectgarbage' (invalid option 'bogus')")
assert(msg(rawlen, 5) == "bad argument #1 to 'rawlen' (table or string expected, got number)")
assert(msg(dofile, "/nonexistent/file.lua"):find("cannot open /nonexistent/file.lua", 1, true))
do
    local closedWith2
    assert(msg(function()
        local guard <close> = setmetatable({}, {__close = function(_, err) closedWith2 = err end})
        assert(false, "closing")
    end) == "@: closing" and tostring(closedWith2):find("closing", 1, true))
end
print("ok")
