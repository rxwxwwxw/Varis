/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/*
** varis - Unit tests for Standard Libraries (Phase 4)
*/

module tests.unit.test_libs;

import varis;
import std.stdio : writeln, stdout;

void testBaseLibrary() {
    auto state = new LuaState();
    openLibs(state);

    // type, tostring, tonumber
    auto res1 = state.doString(q"{
        return type(123), type("abc"), type({}), type(nil), type(true)
    }");
    assert(res1.length == 5);
    assert(toLuaString(res1[0]) == "number");
    assert(toLuaString(res1[1]) == "string");
    assert(toLuaString(res1[2]) == "table");
    assert(toLuaString(res1[3]) == "nil");
    assert(toLuaString(res1[4]) == "boolean");

    auto res2 = state.doString("return tonumber('42'), tonumber('2.5'), tonumber('10', 2)");
    assert(res2.length == 3);
    assert(res2[0].match!((long i) => i == 42L, _ => false));
    assert(res2[1].match!((double d) => d == 2.5, _ => false));
    assert(res2[2].match!((long i) => i == 2L, _ => false));

    // assert and pcall
    auto res3 = state.doString(q"{
        local ok, err = pcall(function()
            assert(false, "my assertion")
        end)
        return ok, err
    }");
    assert(res3.length == 2);
    assert(!isTruthy(res3[0]));
    assert(toLuaString(res3[1]) == "stdin:3: my assertion");

    // select
    auto res4 = state.doString("return select('#', 10, 20, 30), select(2, 'a', 'b', 'c')");
    assert(res4.length == 3);
    assert(res4[0].match!((long i) => i == 3L, _ => false));
    assert(toLuaString(res4[1]) == "b");
    assert(toLuaString(res4[2]) == "c");

    // ipairs
    auto res5 = state.doString(q"{
        local t = { 10, 20, 30 }
        local sum = 0
        for i, v in ipairs(t) do
            sum = sum + v
        end
        return sum
    }");
    assert(res5.length == 1);
    assert(res5[0].match!((long i) => i == 60L, _ => false));

    // load
    auto res6 = state.doString(q"{
        local f = load("return 100 + 200")
        return f()
    }");
    assert(res6.length == 1);
    assert(res6[0].match!((long i) => i == 300L, _ => false));

    writeln("  [PASS] testBaseLibrary");
}

void testMathLibrary() {
    auto state = new LuaState();
    openLibs(state);

    auto res = state.doString(q"{
        local a = math.abs(-42)
        local f = math.floor(3.7)
        local c = math.ceil(3.2)
        local s = math.sqrt(16)
        local m = math.max(1, 10, 5)
        local t1 = math.type(12)
        local t2 = math.type(12.5)
        return a, f, c, s, m, t1, t2
    }");

    assert(res.length == 7);
    assert(res[0].match!((long i) => i == 42L, _ => false));
    assert(res[1].match!((long i) => i == 3L, _ => false));
    assert(res[2].match!((long i) => i == 4L, _ => false));
    assert(res[3].match!((long i) => i == 4L, (double d) => d == 4.0, _ => false));
    assert(res[4].match!((long i) => i == 10L, _ => false));
    assert(toLuaString(res[5]) == "integer");
    assert(toLuaString(res[6]) == "float");

    writeln("  [PASS] testMathLibrary");
}

void testStringLibrary() {
    auto state = new LuaState();
    openLibs(state);

    // sub, upper, lower, rep, reverse
    auto res1 = state.doString(q"{
        local s = "Hello World"
        return s:sub(1, 5), s:upper(), s:lower(), s:reverse(), string.rep("ab", 3)
    }");
    assert(res1.length == 5);
    assert(toLuaString(res1[0]) == "Hello");
    assert(toLuaString(res1[1]) == "HELLO WORLD");
    assert(toLuaString(res1[2]) == "hello world");
    assert(toLuaString(res1[3]) == "dlroW olleH");
    assert(toLuaString(res1[4]) == "ababab");

    // Pattern matching: find, match, captures
    auto res2 = state.doString(q"{
        local s = "order: 12345 item"
        local num = string.match(s, "%d+")
        local start, finish = string.find(s, "12345")
        return num, start, finish
    }");
    assert(res2.length == 3);
    assert(toLuaString(res2[0]) == "12345");
    assert(res2[1].match!((long i) => i == 8L, _ => false));
    assert(res2[2].match!((long i) => i == 12L, _ => false));

    // Balanced pattern %b()
    auto res3 = state.doString(q"{
        local s = "foo (bar (baz)) qux"
        local b = string.match(s, "%b()")
        return b
    }");
    assert(res3.length == 1);
    assert(toLuaString(res3[0]) == "(bar (baz))");

    // format
    auto res4 = state.doString("return string.format('hello %s, number %d', 'alex', 42)");
    assert(res4.length == 1);
    assert(toLuaString(res4[0]) == "hello alex, number 42");

    state.doString(q"{
        assert(string.reverse('\xff\0\xc3\xa9') == '\xa9\xc3\0\xff')
        for width = 1, 16 do
            local encoded = string.pack('>i' .. width, -1)
            assert(encoded == string.rep('\xff', width))
            assert(string.unpack('>i' .. width, encoded) == -1)
        end
        local encoded = string.pack('<!8 b I4 c3 s2 z', -2, 0xfedcba98, 'a', 'b\0c', 'tail')
        local a, b, c, d, e, nextpos = string.unpack('<!8 b I4 c3 s2 z', encoded)
        assert(a == -2 and b == 0xfedcba98 and c == 'a\0\0' and d == 'b\0c' and e == 'tail')
        assert(nextpos == #encoded + 1 and string.sub(encoded, 2, 4) == '\0\0\0')
        assert(string.packsize('!8 b Xi8') == 8)
        assert(string.unpack('>i2', '\xff\xfe', -2) == -2)
        assert(string.unpack('f', string.pack('f', 1.5)) == 1.5)
        assert(string.unpack('d', string.pack('d', -math.huge)) == -math.huge)
        assert(not pcall(string.pack, 'b', 128))
        assert(not pcall(string.pack, 'B', -1))
        assert(not pcall(string.pack, 'i1', 1.5))
        assert(not pcall(string.pack, 'z', 'a\0b'))
        assert(not pcall(string.packsize, 's'))
        assert(not pcall(string.unpack, '>i9', '\1' .. string.rep('\0', 8)))
        assert(not pcall(string.unpack, 's1', '\4ab'))
        assert(not pcall(string.unpack, 'z', 'abc'))
    }");
    writeln("  [PASS] testStringLibrary");
}

void testTableLibrary() {
    auto state = new LuaState();
    openLibs(state);

    // insert, remove, concat, pack, unpack
    auto res1 = state.doString(q"{
        local t = { "a", "b", "c" }
        table.insert(t, "d")
        local removed = table.remove(t, 2)
        local joined = table.concat(t, "-")
        return removed, joined
    }");
    assert(res1.length == 2);
    assert(toLuaString(res1[0]) == "b");
    assert(toLuaString(res1[1]) == "a-c-d");

    // sort
    auto res2 = state.doString(q"{
        local t = { 5, 2, 8, 1, 9 }
        table.sort(t)
        return table.concat(t, ",")
    }");
    assert(res2.length == 1);
    assert(toLuaString(res2[0]) == "1,2,5,8,9");

    writeln("  [PASS] testTableLibrary");
}

void testCoroutineLibrary() {
    auto state = new LuaState();
    openLibs(state);

    // Coroutine create, resume, yield, status
    string coroCode = q"{
        local co = coroutine.create(function(start)
            local y1 = coroutine.yield(start + 1)
            local y2 = coroutine.yield(y1 + 10)
            return y2 + 100
        end)

        local s1 = coroutine.status(co)
        local ok1, val1 = coroutine.resume(co, 5)
        local s2 = coroutine.status(co)
        local ok2, val2 = coroutine.resume(co, 20)
        local ok3, val3 = coroutine.resume(co, 50)
        local s3 = coroutine.status(co)

        return val1, val2, val3, s1, s2, s3
    }";
    auto res = state.doString(coroCode);
    assert(res.length == 6);
    assert(res[0].match!((long i) => i == 6L, _ => false));
    assert(res[1].match!((long i) => i == 30L, _ => false));
    assert(res[2].match!((long i) => i == 150L, _ => false));
    assert(toLuaString(res[3]) == "suspended");
    assert(toLuaString(res[4]) == "suspended");
    assert(toLuaString(res[5]) == "dead");

    state.doString(q"{
        local main, ismain = coroutine.running()
        assert(type(main) == 'thread' and ismain and coroutine.status(main) == 'running')
        assert(not coroutine.isyieldable(main) and not coroutine.isyieldable())
        assert(not coroutine.resume(main))
        local co
        co = coroutine.create(function()
            local self, mainflag = coroutine.running()
            assert(self == co and not mainflag and coroutine.status(main) == 'normal')
            assert(coroutine.status(self) == 'running' and coroutine.isyieldable(self))
            coroutine.wrap(function() assert(coroutine.status(co) == 'normal') end)()
            coroutine.yield(self)
            return coroutine.running()
        end)
        assert(coroutine.isyieldable(co))
        local ok, self = coroutine.resume(co)
        assert(ok and self == co and coroutine.status(main) == 'running')
        local ok, self, mainflag = coroutine.resume(co)
        assert(ok and self == co and not mainflag and coroutine.status(co) == 'dead')
        assert(not pcall(coroutine.isyieldable, 1))
        local marker = {}
        local failed = coroutine.create(function() error(marker) end)
        local ok, reason = coroutine.resume(failed)
        assert(not ok and reason == marker)
        local ok, reason = pcall(coroutine.wrap(function() error(marker) end))
        assert(not ok and reason == marker)
    }");
    state.doString(q"{
        local main = coroutine.running()
        local function closer(fn) return setmetatable({}, {__close = fn}) end
        local ran, closed = false, false
        local fresh = coroutine.create(function() ran = true end)
        assert(coroutine.close(fresh) and not ran and coroutine.status(fresh) == 'dead')
        assert(not coroutine.resume(fresh) and coroutine.isyieldable(fresh))
        local co = coroutine.create(function()
            pcall(function()
                local x <close> = closer(function(_, err)
                    assert(err == nil and not coroutine.isyieldable()); closed = true
                end)
                coroutine.yield()
                ran = true
            end)
            ran = true
        end)
        assert(coroutine.resume(co) and not closed)
        assert(coroutine.close(co) and closed and not ran)
        assert(coroutine.close(co))
        local marker, replacement = {}, {}
        closed = false
        co = coroutine.create(function()
            local x <close> = closer(function(_, err)
                assert(err == marker); closed = true; error(replacement)
            end)
            error(marker)
        end)
        local ok, err = coroutine.resume(co)
        assert(not ok and err == marker and not closed and coroutine.status(co) == 'dead')
        local ok, err = coroutine.close(co)
        assert(not ok and err == replacement and closed)
        assert(coroutine.close(co))
        local sequence = ''
        co = coroutine.create(function()
            local a <close> = closer(function(_, err) assert(err == 10); sequence = sequence .. 'a'; error(20) end)
            local b <close> = closer(function(_, err) assert(err == nil); sequence = sequence .. 'b'; error(10) end)
            coroutine.yield()
        end)
        assert(coroutine.resume(co))
        local ok, err = coroutine.close(co)
        assert(not ok and err == 20 and sequence == 'ba')
        co = coroutine.create(function()
            local x <close> = closer(function() coroutine.close(co) end)
            coroutine.yield()
        end)
        assert(coroutine.resume(co))
        local ok, err = coroutine.close(co)
        assert(not ok and string.find(err, 'running coroutine'))
        local ok, err = pcall(coroutine.close, main)
        assert(not ok and string.find(err, 'running coroutine'))
        assert(not pcall(coroutine.close, 1))
        local boundary = coroutine.wrap(function()
            assert(not pcall(table.sort, {3, 2, 1}, coroutine.yield))
            assert(coroutine.isyieldable())
            string.gsub('a', '.', function()
                assert(not coroutine.isyieldable()); return 'b'
            end)
            assert(coroutine.isyieldable())
            coroutine.yield(20)
            return 30
        end)
        assert(boundary() == 20 and boundary() == 30)

        closed = false
        local ok, err = pcall(coroutine.wrap(function()
            local x <close> = closer(function(_, err) assert(err == marker); closed = true end)
            error(marker)
        end))
        assert(not ok and err == marker and closed)
        co = coroutine.create(function()
            local ok, err = pcall(function()
                local x <close> = closer(function(_, err) assert(err == marker); closed = true end)
                error(marker)
            end)
            assert(not ok and err == marker and closed)
        end)
        assert(coroutine.resume(co))
    }");
    writeln("  [PASS] testCoroutineLibrary");
}

void testUtf8Library() {
    auto state = new LuaState();
    openLibs(state);

    auto res = state.doString(q"{
        local s = utf8.char(0x61, 0x62, 0x4e2d, 0x6587)
        local l = utf8.len(s)
        return s, l
    }");
    assert(res.length == 2);
    assert(toLuaString(res[0]) == "ab中文");
    assert(res[1].match!((long i) => i == 4L, _ => false));
    state.doString(q"{
        local s = 'a' .. utf8.char(0x4e2d) .. 'b'
        assert(utf8.offset(s, 2) == 2 and utf8.offset(s, -1) == 5)
        assert(utf8.offset(s, 0, 3) == 2 and utf8.offset(s, 5) == nil)
        assert(utf8.len(s, 2, 2) == 1 and utf8.codepoint(s, 2, 2) == 0x4e2d)
        local n, position = utf8.len('a\xff')
        assert(n == nil and position == 2)
        local extended = utf8.char(0x7fffffff, 0xd800)
        assert(utf8.len(extended) == nil and utf8.len(extended, 1, -1, true) == 2)
        local a, b = utf8.codepoint(extended, 1, -1, true)
        assert(a == 0x7fffffff and b == 0xd800)
        local count = 0
        for index, code in utf8.codes(s) do
            count = count + 1
            assert(index == utf8.offset(s, count))
        end
        assert(count == 3)
        assert(not pcall(utf8.codes, '\x80'))
        assert(not pcall(utf8.len, 'abc', 0))
        count = 0
        for value in string.gmatch('a b', '%w*') do count = count + 1 end
        assert(count == 2)
        local iter = string.gmatch('abc', '()')
        assert(iter() == 1 and iter() == 2 and iter() == 3 and iter() == 4 and iter() == nil)
        assert(string.gsub('abc', '%w', '%1%0') == 'aabbcc')
        assert(string.gsub('a b cd', ' *', '-') == '-a-b-c-d-')
    }");

    writeln("  [PASS] testUtf8Library");
}

void testLogicLibrary() {
    auto state = new LuaState();
    openLibs(state);

    auto res = state.doString(q"{
        assert(logic ~= nil)
        assert(package.loaded.logic == logic)
        assert(logic.global ~= nil)

        local s1 = symbol("alpha")
        local s2 = logic.symbol("alpha")
        assert(s1 == s2)
        assert(type(s1) == "symbol")
        assert(logic.symbolname(s1) == "alpha")

        local w = logic.world()
        assert(w ~= nil)
        logic.add(w, "edge", s1, symbol("beta"))
        logic.retract(w, "edge", s1, symbol("beta"))

        local ew = logic.emptyworld()
        assert(ew ~= nil)

        return true
    }");
    assert(res.length == 1 && isTruthy(res[0]));

    writeln("  [PASS] testLogicLibrary");
}

void testEnvironmentsAndUpvalues() {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        local env = {x = 7}
        local f = assert(load('x = x + 1; return x', 'env', 't', env))
        local name, value = debug.getupvalue(f, 1)
        assert(name == '_ENV' and value == env)
        assert(f() == 8 and env.x == 8 and _G.x == nil)
        local outer = 4
        local function first() return outer end
        local function second() return outer end
        assert(debug.upvalueid(first, 1) == debug.upvalueid(second, 1))
        assert(debug.setupvalue(first, 1, 12) == 'outer' and second() == 12)
        local function make() local other = 3; return function() return other end end
        local third = make()
        debug.upvaluejoin(third, 1, first, 1)
        assert(third() == 12)
        assert(select('#', debug.getupvalue(first, 9)) == 0)
        assert(debug.upvalueid(first, 9) == nil)  -- ldblib.c: invalid indices give fail, not an error
        do
            local _ENV = {x = 23}
            local function nested() return x end
            x = x + 1
            env.nested = nested
        end
        assert(env.nested() == 24)
        assert(collectgarbage('isrunning'))
        collectgarbage('stop'); collectgarbage('stop')
        assert(not collectgarbage('isrunning'))
        collectgarbage('restart'); collectgarbage('restart')
        assert(collectgarbage('isrunning') and collectgarbage('count') >= 0)
        assert(collectgarbage('collect') == 0)
        assert(not pcall(collectgarbage, 'invalid'))
        local pieces = {'return ', '12', ''}
        local index = 0
        local reader = function() index = index + 1; return pieces[index] end
        assert(assert(load(reader))() == 12)
        assert(assert(load(function() return nil end))() == nil)
        assert(not load(function() return true end))
        local fn, reason = load('return 1', 'text', 'b')
        assert(fn == nil and string.find(reason, 'attempt to load a text chunk'))
        local marker = {}
        fn, reason = load(function() error(marker) end)
        assert(fn == nil and reason == marker)
        assert(math.type('2' + '3') == 'integer' and -' 3e0 ' == -3)
        assert(math.type(tonumber('3.0')) == 'float' and math.type(tonumber('3e0')) == 'float')
        assert(math.type(-'10') == 'integer')
        assert(tonumber('9223372036854775807') == math.maxinteger)
        assert(tonumber('-9223372036854775808') == math.mininteger)
        assert(math.type(tonumber('9223372036854775808')) == 'float')
        assert(tonumber('0xffffffffffffffff') == -1 and tonumber('0x10000000000000000') == 0)
        assert(tonumber('12\0junk') == nil and tonumber('nan') == nil and tonumber('infinity') == nil)
        local info = debug.getinfo(f, 'Su')
        assert(info.source == 'env' and info.what == 'main' and info.linedefined == 0)
        assert(info.currentline == nil and info.nups == 1 and info.isvararg)
        assert(debug.getinfo(print, 'S').short_src == '[C]')
        assert(debug.getinfo(print, 'u').isvararg)
        assert(debug.getinfo(print, 'L').activelines == nil)
        assert(not pcall(debug.getinfo, f, 'invalid'))
        assert(debug.getinfo(-1) == nil)
    }");
    writeln("  [PASS] testEnvironmentsAndUpvalues");
}

void testDebugLocals() {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        local function inspect(a, b, ...)
            local x = 10
            local name, value = debug.getlocal(1, 1)
            assert(name == 'a' and value == a)
            assert(debug.getlocal(inspect, 1) == 'a' and debug.getlocal(inspect, 2) == 'b')
            assert(debug.getlocal(inspect, 3) == nil and debug.getlocal(print, 1) == nil)
            do
                local x = 20
                local n, v = debug.getlocal(1, 6)
                assert(n == 'x' and v == 20)
            end
            assert(debug.setlocal(1, 3, 30) == 'x' and x == 30)
            local n, v = debug.getlocal(1, -1)
            assert(n == '(vararg)' and v == 40)
            assert(debug.setlocal(1, -1, 50) == '(vararg)')
            assert(debug.getlocal(1, -100) == nil and debug.setlocal(1, 100000, 1) == nil)
            assert(not pcall(debug.getlocal, 100000, 1))
            assert(not pcall(debug.setlocal, 100000, 1, 2))
            assert(not pcall(debug.setlocal, 1, 1))
            return x, ...
        end
        local a, b, c = inspect(1, 2, 40, nil)
        assert(a == 30 and b == 50 and c == nil)
        local co = coroutine.create(function(a, ...)
            local x = 10
            local function captured() return x end
            coroutine.yield(captured)
            return a, x, ...
        end)
        local ok, captured = coroutine.resume(co, 2, 3)
        assert(ok and captured() == 10)
        local n, v = debug.getlocal(co, 1, 2)
        assert(n == 'x' and v == 10)
        assert(debug.setlocal(co, 1, 2, 40) == 'x' and captured() == 40)
        assert(debug.setlocal(co, 1, -1, 99) == '(vararg)')
        local n, value = debug.getlocal(co, 0, 1)
        assert(n == '(C temporary)' and value == captured)
        local ok, a, b, c = coroutine.resume(co)
        assert(ok and a == 2 and b == 40 and c == 99)
        local seen = false
        co = coroutine.create(function(parameter) local body = 1; return parameter end)
        debug.sethook(co, function(event)
            if event == 'call' then
                local n, value = debug.getlocal(2, 1)
                assert(n == 'parameter' and value == 7)
                seen = true
            end
        end, 'c')
        assert(coroutine.resume(co, 7) and seen)
    }");
    state.doString(q"{
        local getter
        local function target(...)
            local value = 10
            getter = function() return value end
            local function edit(...)
                assert(debug.setlocal(2, 1, 42) == 'value')
                return ...
            end
            local function expanded(...) return edit(...) end
            expanded(...)
            assert(getter() == 42 and value == 42)
            return ...
        end
        local args = {}
        for i = 1, 200 do args[i] = i end
        assert(select('#', target(table.unpack(args))) == 200 and getter() == 42)
    }");
    writeln("  [PASS] testDebugLocals");
}

void testDebugHooks() {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        assert(debug.gethook() == nil)
        local marker = {}
        assert(debug.traceback(marker) == marker)
        assert(string.find(debug.traceback('message'), '^message\nstack traceback:'))
        assert(not string.find(debug.traceback(), "'debug.traceback'"))
        assert(string.find(debug.traceback(nil, 0), "'debug.traceback'"))
        assert(debug.traceback(nil, 100000) == 'stack traceback:')
        local function recurse(n)
            if n == 0 then return debug.traceback() end
            local result = recurse(n - 1)
            return result
        end
        assert(string.find(recurse(35), 'skipping %d+ levels'))
        local suspended = coroutine.create(function() coroutine.yield() end)
        assert(coroutine.resume(suspended))
        assert(string.find(debug.traceback(suspended), "function 'coroutine.yield'"))
        assert(not string.find(debug.traceback(suspended, nil, 1), "function 'coroutine.yield'"))
        assert(coroutine.close(suspended))

        local events = {}
        local co = coroutine.create(function()
            coroutine.yield(10)
            return 20
        end)
        local hook = function(event, line)
            assert(not coroutine.isyieldable())
            assert(debug.getinfo(2).func ~= nil)
            events[#events + 1] = event
            if event == 'line' then assert(type(line) == 'number') else assert(line == nil) end
        end
        debug.sethook(co, hook, 'lrc')
        local fn, mask, count = debug.gethook(co)
        assert(fn == hook and mask == 'crl' and count == 0 and debug.gethook() == nil)
        local ok, value = coroutine.resume(co)
        assert(ok and value == 10 and debug.getinfo(co, 0).what == 'C')
        assert(debug.getinfo(co, 1).func ~= nil and debug.getinfo(co, 100) == nil)
        assert(coroutine.resume(co) and coroutine.status(co) == 'dead')
        assert(table.concat(events, ',') == 'call,line,call,return,line,return')
        local calls = 0
        debug.sethook(function(event)
            assert(event == 'count'); calls = calls + 1
        end, '', 4)
        local sum = 0
        for i = 1, 20 do sum = sum + i end
        debug.sethook()
        assert(sum == 210 and calls > 0 and debug.gethook() == nil)
        local marker = {}
        co = coroutine.create(function() return 1 end)
        debug.sethook(co, function() error(marker) end, 'c')
        local ok, reason = coroutine.resume(co)
        assert(not ok and reason == marker)
        debug.sethook(co)
        assert(not coroutine.close(co))
        assert(coroutine.close(co))
        co = coroutine.create(function() return 1 end)
        debug.sethook(co, function() coroutine.yield() end, 'l')
        local ok, reason = coroutine.resume(co)
        assert(not ok and string.find(reason, 'C%-call boundary'))
        debug.sethook(co)
        coroutine.close(co)
        debug.sethook(function() end, 'c', 9)
        local inherited = coroutine.create(function() end)
        debug.sethook()
        local fn, mask, count = debug.gethook(inherited)
        assert(fn == nil and mask == 'c' and count == 9)
        assert(not pcall(debug.sethook, false, 'c'))
        assert(not pcall(debug.sethook, function() end, {}))
        local f = assert(load('return function() end', '=' .. string.rep('x', 80)))()
        assert(debug.getinfo(f, 'S').short_src == string.rep('x', 59))
        f = assert(load('return function() end', '@' .. string.rep('x', 80)))()
        assert(debug.getinfo(f, 'S').short_src == '...' .. string.rep('x', 56))
        f = assert(load('return function() end', 'abc\ndef'))()
        assert(debug.getinfo(f, 'S').short_src == '[string "abc..."]')
    }");
    state.doString(q"{
        local count = 0
        debug.sethook(function() count = count + 1 end, '', 1)
        count = 0
        for i = 1, 1000 do end
        debug.sethook()
        assert(count > 1000 and count < 1012)
    }");
    writeln("  [PASS] testDebugHooks");
}

int main() {
    writeln("Running varis Standard Libraries (Phase 4) Unit Tests...");
    testBaseLibrary();
    testDebugHooks();
    testDebugLocals();
    testEnvironmentsAndUpvalues();
    testMathLibrary();
    testStringLibrary();
    testTableLibrary();
    testCoroutineLibrary();
    testUtf8Library();
    testLogicLibrary();
    writeln("All Standard Libraries Tests Passed Successfully!");
    return 0;
}
