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
** varis - Unit tests for Runtime & VM (Phase 3)
*/

module tests.unit.test_vm;

import varis;
import std.stdio : writeln;

void testBasicExecution() {
    auto state = new LuaState();
    auto res = state.doString("local x = 10; local y = 20; return x + y * 2;");
    assert(res.length == 1);
    assert(res[0].match!((long i) => i == 50L, _ => false));
    writeln("  [PASS] testBasicExecution");
}

void testControlFlow() {
    auto state = new LuaState();

    // If-elseif-else
    string ifCode = q"{
        local function check(x)
            if x > 10 then
                return "big"
            elseif x == 10 then
                return "equal"
            else
                return "small"
            end
        end
        return check(15), check(10), check(3)
    }";
    auto ifRes = state.doString(ifCode);
    assert(ifRes.length == 3);
    assert(toLuaString(ifRes[0]) == "big");
    assert(toLuaString(ifRes[1]) == "equal");
    assert(toLuaString(ifRes[2]) == "small");

    // While loop
    auto whileRes = state.doString(q"{
        local sum = 0
        local i = 1
        while i <= 10 do
            sum = sum + i
            i = i + 1
        end
        return sum
    }");
    assert(whileRes.length == 1);
    assert(whileRes[0].match!((long i) => i == 55L, _ => false));

    // Numeric For loop
    auto forRes = state.doString(q"{
        local sum = 0
        for i = 1, 10 do
            sum = sum + i
        end
        return sum
    }");
    assert(forRes.length == 1);
    assert(forRes[0].match!((long i) => i == 55L, _ => false));

    // Break statement
    auto breakRes = state.doString(q"{
        local i = 0
        while true do
            i = i + 1
            if i == 5 then break end
        end
        return i
    }");
    assert(breakRes.length == 1);
    assert(breakRes[0].match!((long i) => i == 5L, _ => false));

    writeln("  [PASS] testControlFlow");
}

void testRecursionAndClosures() {
    auto state = new LuaState();

    // Factorial recursion
    string factCode = q"{
        local function fact(n)
            if n <= 1 then
                return 1
            else
                return n * fact(n - 1)
            end
        end
        return fact(5)
    }";
    auto factRes = state.doString(factCode);
    assert(factRes.length == 1);
    assert(factRes[0].match!((long i) => i == 120L, _ => false));

    // Closures and mutable upvalues
    string closureCode = q"{
        local function makeCounter(start)
            local count = start
            return function()
                count = count + 1
                return count
            end
        end

        local c1 = makeCounter(10)
        local c2 = makeCounter(100)
        return c1(), c1(), c2(), c1()
    }";
    auto cRes = state.doString(closureCode);
    assert(cRes.length == 4);
    assert(cRes[0].match!((long i) => i == 11L, _ => false));
    assert(cRes[1].match!((long i) => i == 12L, _ => false));
    assert(cRes[2].match!((long i) => i == 101L, _ => false));
    assert(cRes[3].match!((long i) => i == 13L, _ => false));

    writeln("  [PASS] testRecursionAndClosures");
}

void testTablesAndMetamethods() {
    auto state = new LuaState();

    // Table operations
    string tableCode = q"{
        local t = { x = 10, 20, 30 }
        t.y = 40
        t[4] = 50
        return t.x + t[1] + t[2] + t.y + t[4]
    }";
    auto tRes = state.doString(tableCode);
    assert(tRes.length == 1);
    assert(tRes[0].match!((long i) => i == 150L, _ => false));

    // Metamethod __add
    string metaCode = q"{
        local mt = {
            __add = function(a, b)
                return { val = a.val + b.val }
            end
        }
        local v1 = { val = 10 }
        local v2 = { val = 25 }
        setmetatable(v1, mt)
        local v3 = v1 + v2
        return v3.val
    }";

    // Register setmetatable global so script can use it
    state.registerGlobal("setmetatable", (void* s, LuaValue[] args) {
        if (args.length >= 2 && isTable(args[0]) && isTable(args[1])) {
            auto t = args[0].match!((LuaTable tbl) => tbl, _ => null);
            auto mt = args[1].match!((LuaTable tbl) => tbl, _ => null);
            t.metatable = mt;
            return [args[0]];
        }
        return [luaNil()];
    });

    auto metaRes = state.doString(metaCode);
    assert(metaRes.length == 1);
    assert(metaRes[0].match!((long i) => i == 35L, _ => false));

    writeln("  [PASS] testTablesAndMetamethods");
}

void testLogicalOperators() {
    auto state = new LuaState();

    // Short-circuit and / or
    auto res1 = state.doString("return nil and 10 or 20;");
    assert(res1.length == 1);
    assert(res1[0].match!((long i) => i == 20L, _ => false));

    auto res2 = state.doString("return 'first' or 'second';");
    assert(res2.length == 1);
    assert(toLuaString(res2[0]) == "first");

    auto res3 = state.doString("return false or 'default';");
    assert(res3.length == 1);
    assert(toLuaString(res3[0]) == "default");

    writeln("  [PASS] testLogicalOperators");
}

void testArithmeticFastPaths() {
    assert(isNil(LuaValue.init));
    auto state = new LuaState();
    auto values = state.doString(q"{
        local function missing(a, b) return b end
        local max = 9223372036854775807
        return max + 1, (-max - 1) - 1, max * 2,
               2 + 0.5, '3' - 1, '4' * 2, missing(7)
    }");
    assert(values.length == 7);
    assert(luaRawEqual(values[0], LuaValue(long.min)));
    assert(luaRawEqual(values[1], LuaValue(long.max)));
    assert(luaRawEqual(values[2], LuaValue(-2L)));
    assert(isFloat(values[3]) && luaRawEqual(values[3], LuaValue(2.5)));
    assert(luaRawEqual(values[4], LuaValue(2L)));
    assert(luaRawEqual(values[5], LuaValue(8L)));
    assert(isNil(values[6]));
    writeln("  [PASS] testArithmeticFastPaths");
}

void testGotoAndPrecedence() {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        assert(10 - 3 - 2 == 5)
        assert(24 / 4 / 2 == 3)
        assert(-2^2 == -4 and (-2)^2 == 4)
        assert(2^3^2 == 512 and 2^-2 == 0.25)
        assert(-3 % 5 == 2 and 3 % -5 == -2)
        assert(-3.0 % 5.0 == 2.0 and 3.0 % -5.0 == -2.0)
        assert(-3 // 5 == -1 and 3 // -5 == -1 and -3 // -5 == 0)
        local minimum = -9223372036854775807 - 1
        assert(minimum // -1 == minimum and minimum % -1 == 0)
        assert(3.0 & 5.0 == 1 and 3.0 | 5 == 7 and 3 ~ 5.0 == 6)
        assert(~3.0 == -4)
        assert(-1 >> 1 == 9223372036854775807)
        assert(1 << -1 == 0 and 8 >> -1 == 16)
        assert(1 << 64 == 0 and -1 >> 64 == 0 and 1 << minimum == 0)
        local function multiple() return 1, 2, 3 end
        local a, b = (multiple())
        assert(a == 1 and b == nil)
        assert(select('#', (multiple())) == 1)
        assert(#{(multiple())} == 1)
        local n = 0
        ::again:: n = n + 1
        if n < 3 then goto again end
        do goto done; local skipped = 12; ::done:: end
        assert(n == 3)
        local functions = {}
        local i = 0
        ::capture::
        local value = i
        functions[i + 1] = function() return value end
        i = i + 1
        if i < 3 then goto capture end
        assert(functions[1]() == 0 and functions[2]() == 1 and functions[3]() == 2)
        local function invalid(code, message)
            local fn, err = load(code)
            assert(fn == nil and string.find(err, message, 1, true))
        end
        invalid('goto missing', "label 'missing'")
        invalid('goto inner; do ::inner:: end', "label 'inner'")
        invalid('::a:: ::a::', "label 'a'")
        invalid('goto a; local x; ::a:: print(x)', "local 'x'")
        invalid('do local b; goto a end; local x; ::a:: print(x)', "local 'x'")
        invalid('repeat goto a; local x; ::a:: until x', "local 'x'")
    }");
    writeln("  [PASS] testGotoAndPrecedence");
}

void testCloseAndConst() {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        local closed = {}
        local function object(id)
            return setmetatable({}, {__close = function(self, err)
                closed[#closed + 1] = {id, err}
            end})
        end
        do local a <close> = object(1); local b <close> = object(2) end
        assert(closed[1][1] == 2 and closed[2][1] == 1 and closed[1][2] == nil)
        while true do local a <close> = object(3); break end
        assert(closed[3][1] == 3)
        local function returning()
            local a <close> = object(4)
            return 1, nil, 3
        end
        local a, b, c = returning()
        assert(a == 1 and b == nil and c == 3 and closed[4][1] == 4)
        local marker = {}
        local ok, err = pcall(function()
            local a <close> = object(5)
            error(marker)
        end)
        assert(not ok and err == marker and closed[5][2] == marker)
        ok, err = pcall(function()
            local a <close> = object(6)
            local b <close> = setmetatable({}, {__close = function() error('closing') end})
            error(marker)
        end)
        assert(not ok and err == 'stdin:26: closing' and closed[6][2] == err)
        do local a <close> = nil; local b <close> = false end
        assert(not pcall(function() local a <close> = {} end))
        assert(not load('local a<const> = 1; a = 2'))
        assert(not load('local a<const> = 1; return function() a = 2 end'))
        assert(not load('local a<unknown> = 1'))
        assert(not load('local a<close>, b<close> = nil, nil'))
        do local a<const> = {}; a.x = 3; assert(a.x == 3) end
        do local a = 1; a = 2; assert(a == 2) end
    }");
    writeln("  [PASS] testCloseAndConst");
}

void testTailCalls() {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        local function count(n, ...)
            if n == 0 then return ... end
            return count(n - 1, ...)
        end
        local a, b, c = count(30000, 1, nil, 3)
        assert(a == 1 and b == nil and c == 3)
        local object = {}
        function object:count(n)
            if n == 0 then return self end
            return self:count(n - 1)
        end
        assert(object:count(30000) == object)
        local function leaf() return debug.getinfo(1, 't').istailcall end
        local function transfer() return leaf() end
        assert(transfer())
        assert(coroutine.wrap(function() return count(30000, 'fiber') end)() == 'fiber')
        local target = function(...) return ... end
        for i = 1, 20 do target = setmetatable({i}, {__call = target}) end
        local function forward(...) return target(...) end
        local results = table.pack(forward('end'))
        assert(results.n == 21 and results[1][1] == 1 and results[20][1] == 20 and results[21] == 'end')
        local escaped
        local function capture(n)
            local x = n
            if n == 3 then escaped = function() return x end end
            if n > 0 then return capture(n - 1) end
            return escaped()
        end
        assert(capture(20) == 3)
        local function overflow() return 1 + overflow() end
        assert(not pcall(overflow))
        assert(not pcall(coroutine.wrap(function() return overflow() end)))
        local ok, err = xpcall(function() error('body') end, function() error('handler') end)
        assert(not ok and err == 'error in error handling')
        local order = ''
        local function returning()
            local guard <close> = setmetatable({}, {__close = function() order = order .. 'c' end})
            return (function() order = order .. 'f'; return 7 end)()
        end
        assert(returning() == 7 and order == 'fc')
    }");
    assert(state.callStack.length == 0);
    writeln("  [PASS] testTailCalls");
}

void testForScopeClosing() {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        local order = ''
        local function closing(id)
            return setmetatable({}, {__close = function(_, err) order = order .. id end})
        end
        local function iterator(state, previous)
            previous = previous + 1
            if previous <= state then return previous end
        end
        local function tuple() return iterator, 3, 0, closing('f') end
        local captured = {}
        for i in tuple() do
            local value <close> = closing(tostring(i))
            captured[i] = function() return i end
        end
        assert(order == '123f')
        assert(captured[1]() == 1 and captured[2]() == 2 and captured[3]() == 3)
        order = ''
        local sideEffect = 0
        for i in iterator, 3, 0, closing('f'), (function() sideEffect = sideEffect + 1 end)() do
            local value <close> = closing('b')
            break
        end
        assert(sideEffect == 1 and order == 'bf')
        order = ''
        local marker = {}
        local ok, err = pcall(function()
            for i in iterator, 3, 0, closing('f') do
                local value <close> = closing('e')
                error(marker)
            end
        end)
        assert(not ok and err == marker and order == 'ef')
        local function early()
            for i in iterator, 3, 0, closing('f') do return i end
        end
        assert(early() == 1 and order == 'eff')
        order = ''
        for i = 1, 3 do
            local value <close> = closing(tostring(i))
            captured[i] = function() return i end
        end
        assert(order == '123' and captured[1]() == 1 and captured[2]() == 2 and captured[3]() == 3)
        local function name() local info = debug.getinfo(1, 'n'); return info.name, info.namewhat end
        local a, b = name()
        assert(a == 'name' and b == 'local')
        local object = {field = name}
        a, b = object.field()
        assert(a == 'field' and b == 'field')
        a, b = object:field()
        assert(a == 'field' and b == 'method')
    }");
    writeln("  [PASS] testForScopeClosing");
}

void testRegisterReuseLifetimes() {
    import varis.lib : openLibs;

    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        local function capture(value, ...)
            local saved = value
            local function get() return saved end
            local args = {...}
            local function relay(...) return ... end
            -- Variable results grow the register window while saved is open.
            local result = {relay(table.unpack(args))}
            assert(#result == #args)
            return get
        end
        local args = {}
        for i=1,600 do args[i] = i end
        local keep = capture('kept', table.unpack(args))
        for i=1,100 do assert(capture(i)() == i) end
        assert(keep() == 'kept')
        local co = coroutine.create(function()
            local value = 'suspended'
            local get = function() return value end
            coroutine.yield(get)
            value = 'resumed'
            return get
        end)
        local ok, get = coroutine.resume(co)
        assert(ok and get() == 'suspended')
        for i=1,100 do assert(capture(i)() == i) end
        assert(get() == 'suspended')
        local ok2, get2 = coroutine.resume(co)
        assert(ok2 and get2() == 'resumed' and get() == 'resumed')
        local closed
        local ok3 = pcall(function()
            local value <close> = setmetatable({}, {__close=function()
                closed = capture('closed')
            end})
            error('unwind')
        end)
        assert(not ok3 and closed() == 'closed' and keep() == 'kept')
        for i=1,100 do assert(capture(i)() == i) end
        assert(closed() == 'closed' and keep() == 'kept')
    }");
    writeln("  [PASS] testRegisterReuseLifetimes");
}

void testFrameContextAndHooks() {
    auto state = new LuaState();
    import varis.lib : openLibs;

    openLibs(state);
    state.doString(q"{
        local hits, childHits = 0, 0
        local function recurse(n)
            if n == 0 then return debug.getinfo(1, 'l').currentline end
            local result = recurse(n-1)
            return result
        end
        local co = coroutine.create(function()
            debug.sethook(function() childHits = childHits + 1 end, 'l')
            assert(recurse(80) > 0)
            coroutine.yield('ready')
            assert(recurse(100) > 0)
            debug.sethook()
        end)
        debug.sethook(function() hits = hits + 1 end, '', 3)
        local ok, result = coroutine.resume(co)
        assert(ok and result == 'ready')
        assert(hits > 0 and childHits > 0)
        local before = childHits
        assert(recurse(120) > 0)
        assert(childHits == before)
        assert(coroutine.resume(co))
        assert(childHits > before)
        debug.sethook()
        local stopped = hits
        assert(recurse(100) > 0)
        assert(hits == stopped)
        local lineHits = 0
        debug.sethook(function() lineHits = lineHits + 1 end, 'l')
        for i=1,10 do recurse(2) end
        debug.sethook()
        assert(lineHits > 0)
    }");
    writeln("  [PASS] testFrameContextAndHooks");
}

int main() {
    writeln("Running varis Runtime & VM Unit Tests...");
    testRegisterReuseLifetimes();
    testFrameContextAndHooks();
    testBasicExecution();
    testControlFlow();
    testGotoAndPrecedence();
    testCloseAndConst();
    testForScopeClosing();
    testTailCalls();
    testRecursionAndClosures();
    testTablesAndMetamethods();
    testLogicalOperators();
    testArithmeticFastPaths();
    writeln("All Runtime & VM Tests Passed Successfully!");
    return 0;
}
