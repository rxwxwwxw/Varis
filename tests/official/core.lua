-- Deterministic Lua 5.4 differential checks. No extension syntax or table order.
local function emit(...) print(...) end
emit(10 - 3 - 2, 24 / 4 / 2, -2^2, 2^3^2, 2^-2)
emit(-3 // 5, 3 // -5, -3 % 5, 3 % -5, -3.0 % 5.0)
local minimum = math.mininteger
emit(minimum // -1, minimum % -1, -1 >> 1, 1 << 64, 1 << minimum)
emit(3.0 & 5, 3 | 5.0, 3.0 ~ 5.0, ~3.0, 8 >> -1)
local function multiple() return 1, nil, 3 end
emit(select('#', multiple()), select('#', (multiple())), #{(multiple())})
local functions = {}
local i = 0
::capture::
local value = i
functions[i + 1] = function() return value end
i = i + 1
if i < 3 then goto capture end
emit(functions[1](), functions[2](), functions[3]())
local env = {x = 7}
local chunk = assert(load('x = x + 1; return x', 'env', 't', env))
emit(debug.getupvalue(chunk, 1) == '_ENV', chunk(), env.x)
local order = ''
local function closing(id)
    return setmetatable({}, {__close = function(_, err)
        order = order .. id .. (err == nil and '.' or '!')
    end})
end
do local a <close> = closing('a'); local b <close> = closing('b') end
while true do local c <close> = closing('c'); break end
local ok = pcall(function() local d <close> = closing('d'); error({}) end)
emit(order, ok)
emit(load('local a<const> = 1; a = 2') == nil)
local function tail(n, ...)
    if n == 0 then return ... end
    return tail(n - 1, ...)
end
emit(tail(30000, 'tail', nil, 3))
emit(coroutine.wrap(function() return tail(30000, 'fiber') end)())
local ok, err = xpcall(function() error('body') end, function() error('handler') end)
emit(ok, err)
emit(math.type('2' + '3'), -' 3e0 ')
local parts = {'return ', '12'}
local part = 0
local loaded = assert(load(function() part = part + 1; return parts[part] end, '=reader', 't'))
emit(loaded(), debug.getinfo(loaded, 'S').source)
local text = 'a' .. utf8.char(0x4e2d) .. 'b'
emit(utf8.len(text, 2, 2), utf8.offset(text, -1), utf8.offset(text, 0, 3))
emit(utf8.len('a\xff'))
local extended = utf8.char(0x7fffffff, 0xd800)
emit(utf8.len(extended, 1, -1, true), utf8.codepoint(extended, 1, -1, true))
for index, code in utf8.codes(text) do emit(index, code) end
local matches = {}
for value in string.gmatch('a b', '%w*') do matches[#matches + 1] = value end
emit(table.concat(matches, ','))
emit(string.gsub('abc', '%w', '%1%0'))
emit(string.gsub('a b cd', ' *', '-'))

local binary = string.pack('>!4 b I4 c3 s2 z', -2, 0xfedcba98, 'a', 'b\0c', 'tail')
local bytes = {}
for index = 1, #binary do bytes[index] = string.format('%02x', string.byte(binary, index)) end
emit(table.concat(bytes), string.packsize('!8 b Xi8'))
emit(string.unpack('>!4 b I4 c3 s2 z', binary))
emit(string.unpack('<i16', string.pack('<i16', math.mininteger)))
emit(string.unpack('f d', string.pack('f d', 1.5, -2.25)))
emit(string.byte(string.reverse('\xff\0\xc3\xa9'), 1, 4))

local main, ismain = coroutine.running()
emit(type(main), ismain, coroutine.isyieldable(main), coroutine.status(main))
local co
co = coroutine.create(function()
    local self, mainflag = coroutine.running()
    emit(self == co, mainflag, coroutine.status(main), coroutine.isyieldable(self))
    coroutine.wrap(function() emit(coroutine.status(co)) end)()
    coroutine.yield(7)
end)
emit(coroutine.resume(co))
emit(coroutine.resume(co))
emit(coroutine.status(co))
local marker = {}
local failed = coroutine.create(function() error(marker) end)
local ok, err = coroutine.resume(failed)
emit(ok, err == marker)

local closed = false
local co = coroutine.create(function()
    local x <close> = setmetatable({}, {__close = function(_, err) closed = err end})
    error(43)
end)
emit(coroutine.resume(co))
emit(closed, coroutine.status(co))
emit(coroutine.close(co))
emit(closed, coroutine.close(co))
local sequence = ''
co = coroutine.create(function()
    pcall(function()
        local a <close> = setmetatable({}, {__close = function(_, err) sequence = sequence .. tostring(err); error(20) end})
        local b <close> = setmetatable({}, {__close = function(_, err) sequence = sequence .. tostring(err); error(10) end})
        coroutine.yield()
        sequence = 'BAD'
    end)
    sequence = 'BAD'
end)
emit(coroutine.resume(co))
emit(coroutine.close(co))
emit(sequence, coroutine.close(co))

emit(coroutine.isyieldable(co))

local events = {}
local hooked = coroutine.create(function()
    coroutine.yield(10)
    return 20
end)
local hook = function(event) events[#events + 1] = event end
local function info()
    local fn, mask, count = debug.gethook(hooked)
    emit(fn == hook, mask, count)
end
debug.sethook(hooked, hook, 'lrc')
info()
emit(coroutine.resume(hooked))
emit(debug.getinfo(hooked, 0).what, debug.getinfo(hooked, 1).what)
emit(coroutine.resume(hooked))
emit(table.concat(events, ','))
local count = 0
debug.sethook(function(event) if event == 'count' then count = count + 1 end end, '', 4)
for i = 1, 20 do local n = i * i end
debug.sethook()
emit(count > 0, debug.gethook() == nil)
local f = assert(load('return function() end', '@' .. string.rep('x', 80)))()
emit(debug.getinfo(f, 'S').short_src)

local suspended = coroutine.create(function() coroutine.yield() end)
coroutine.resume(suspended)
emit(string.find(debug.traceback(suspended), "function 'coroutine.yield'") ~= nil)
emit(string.find(debug.traceback(suspended, nil, 1), "function 'coroutine.yield'") == nil)
emit(string.find(debug.traceback(nil, 0), "'debug.traceback'") ~= nil)
emit(debug.traceback(nil, 100000) == 'stack traceback:')
coroutine.close(suspended)

local function inspect(a, b, ...)
    local x = 10
    local name, value = debug.getlocal(1, 1)
    emit(name, value, debug.getlocal(inspect, 2))
    emit(debug.setlocal(1, 3, 30), x)
    emit(debug.getlocal(1, -1))
    emit(debug.setlocal(1, -1, 50))
    return x, ...
end
emit(inspect(1, 2, 40, nil))
local co = coroutine.create(function(a, ...)
    local x = 10
    local function captured() return x end
    coroutine.yield(captured)
    return a, x, ...
end)
local ok, captured = coroutine.resume(co, 2, 3)
emit(debug.getlocal(co, 1, 2))
emit(debug.setlocal(co, 1, 2, 40), captured())
emit(debug.setlocal(co, 1, -1, 99))
emit(coroutine.resume(co))

local order = ''
local function closing(id)
    return setmetatable({}, {__close = function() order = order .. id end})
end
local function iterator(state, previous)
    previous = previous + 1
    if previous <= state then return previous end
end
local captured = {}
for i in iterator, 3, 0, closing('f') do
    local value <close> = closing(tostring(i))
    captured[i] = function() return i end
end
emit(order, captured[1](), captured[2](), captured[3]())
order = ''
for i = 1, 3 do
    local value <close> = closing(tostring(i))
    captured[i] = function() return i end
end
emit(order, captured[1](), captured[2](), captured[3]())
local function caller() local info = debug.getinfo(1, 'n'); return info.name, info.namewhat end
emit(caller())
local object = {field = caller}
emit(object.field())
emit(object:field())

local count = 0
debug.sethook(function() count = count + 1 end, '', 1)
count = 0
for i = 1, 1000 do end
debug.sethook()
emit(count > 1000 and count < 1012)
