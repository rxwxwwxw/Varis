/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

/*
** dlua - Unit tests for Foundation (types, table, state, exception)
*/

module tests.unit.test_foundation;

import dlua;
import std.stdio : writeln, writefln;
import std.math : floatTraits, isNaN;

void testTypes() {
    // Nil
    auto vNil = luaNil();
    assert(isNil(vNil));
    assert(!isTruthy(vNil));
    assert(typeOf(vNil) == LuaType.Nil);
    assert(typeName(vNil) == "nil");

    // Boolean
    auto vTrue = luaValue(true);
    auto vFalse = luaValue(false);
    assert(isTruthy(vTrue));
    assert(!isTruthy(vFalse));
    assert(typeOf(vTrue) == LuaType.Boolean);
    assert(typeName(vFalse) == "boolean");

    // Numbers
    auto vInt = luaValue(42L);
    auto vFloat = luaValue(3.14);
    auto vFloatInt = luaValue(42.0);

    assert(isNumber(vInt));
    assert(isInteger(vInt));
    assert(!isFloat(vInt));

    assert(isNumber(vFloat));
    assert(!isInteger(vFloat));
    assert(isFloat(vFloat));

    // In Lua, 0 and 0.0 and "" are truthy!
    assert(isTruthy(luaValue(0L)));
    assert(isTruthy(luaValue(0.0)));
    assert(isTruthy(luaValue("")));

    // Mathematical raw equality: 42L == 42.0
    assert(luaRawEqual(vInt, vFloatInt));
    assert(!luaRawEqual(vInt, vFloat));

    // String
    auto vStr = luaValue("hello");
    assert(isString(vStr));
    assert(isTruthy(vStr));
    assert(toLuaString(vStr) == "hello");

    // Symbol (Milestone 1)
    auto vSym = luaValue(Symbol("node1"));
    auto vSym2 = luaValue(Symbol("node1"));
    auto vSymDiff = luaValue(Symbol("node2"));
    assert(isSymbol(vSym));
    assert(isTruthy(vSym));
    assert(typeOf(vSym) == LuaType.Symbol);
    assert(typeName(vSym) == "symbol");
    assert(vSym == vSym2);
    assert(vSym != vSymDiff);
    assert(vSym != vStr); // Symbol distinct from string
    assert(toLuaString(vSym) == ":node1");

    // Dynamic / non-identifier symbol representation
    auto vSymSpecial = luaValue(Symbol("not-an-identifier"));
    assert(toLuaString(vSymSpecial) == ":\"not-an-identifier\"");
    auto vSymBinary = luaValue(Symbol("bin\0ary"));
    assert(vSymBinary == luaValue(Symbol("bin\0ary")));

    // Precision boundary tests (2^53 and 2^63)
    long largeInt1 = 9007199254740992L; // 2^53
    long largeInt2 = 9007199254740993L; // 2^53 + 1
    double largeFloat = 9007199254740992.0; // In double, 2^53 + 1 rounds to 2^53
    assert(luaRawEqual(luaValue(largeInt1), luaValue(largeFloat)));
    assert(!luaRawEqual(luaValue(largeInt2), luaValue(largeFloat))); // Must NOT equal due to precision loss!
    assert(luaValue(largeInt1).toHash() == luaValue(largeFloat).toHash());

    // 2^63 boundary check in floatToInteger
    long outInt;
    assert(!floatToInteger(9223372036854775808.0, outInt)); // 2^63 cannot fit in long
    assert(floatToInteger(-9223372036854775808.0, outInt)); // -2^63 fits in long.min
    assert(outInt == long.min);
    assert(!floatToInteger(-9223372036854775808.0 - 2048.0, outInt)); // below long.min

    // RelTuple (Milestone 1)
    import dlua.logic.model : RelTuple;

    auto tZero = RelTuple([]);
    assert(tZero.length == 0);
    assert(tZero == RelTuple([]));

    auto tNil = RelTuple([luaNil(), luaValue(1L)]);
    assert(tNil.length == 2);
    assert(tNil == RelTuple([luaNil(), luaValue(1.0)])); // integer and float match

    bool nanCaught = false;
    try {
        import std.math : floatTraits;

        double nanVal = double.nan;
        auto tNan = RelTuple([luaValue(nanVal)]);
    } catch (LuaException e) {
        nanCaught = true;
    }
    assert(nanCaught, "NaN in RelTuple must be rejected");

    writeln("  [PASS] testTypes");
}

void testTable() {
    auto t = new LuaTable();

    // 1-based array indexing
    t.rawset(LuaValue(1L), LuaValue("first"));
    t.rawset(LuaValue(2L), LuaValue("second"));
    t.rawset(LuaValue(3L), LuaValue("third"));

    assert(toLuaString(t.rawget(LuaValue(1L))) == "first");
    assert(toLuaString(t.rawget(LuaValue(2L))) == "second");
    assert(toLuaString(t.rawget(LuaValue(3L))) == "third");
    assert(t.rawLen() == 3);

    // Number key normalization: 1.0 == 1
    assert(toLuaString(t.rawget(LuaValue(1.0))) == "first");
    t.rawset(LuaValue(2.0), LuaValue("updated-second"));
    assert(toLuaString(t.rawget(LuaValue(2L))) == "updated-second");

    // Hash part with string keys
    t.rawset(LuaValue("foo"), LuaValue("bar"));
    assert(toLuaString(t.rawget(LuaValue("foo"))) == "bar");
    assert(isNil(t.rawget(LuaValue("missing"))));

    // Length with border
    assert(t.rawLen() == 3);

    // Remove key
    t.rawset(LuaValue("foo"), luaNil());
    assert(isNil(t.rawget(LuaValue("foo"))));

    // Error on nil key
    bool caughtNilKey = false;
    try {
        t.rawset(luaNil(), LuaValue(123L));
    } catch (LuaException e) {
        caughtNilKey = true;
    }
    assert(caughtNilKey);

    // Error on NaN key
    bool caughtNaNKey = false;
    try {
        t.rawset(LuaValue(double.nan), LuaValue(123L));
    } catch (LuaException e) {
        caughtNaNKey = true;
    }
    assert(caughtNaNKey);

    // Table iteration (next)
    auto tIter = new LuaTable();
    tIter.rawset(LuaValue(1L), LuaValue("a"));
    tIter.rawset(LuaValue(2L), LuaValue("b"));
    tIter.rawset(LuaValue("x"), LuaValue("c"));

    LuaValue k = luaNil();
    LuaValue v;
    size_t count = 0;
    while (tIter.next(k, k, v)) {
        count++;
    }
    assert(count == 3);

    writeln("  [PASS] testTable");
}

void testStateAndPCall() {
    auto state = new LuaState();

    // Check default globals
    assert(!isNil(state.getGlobal("_G")));
    assert(toLuaString(state.getGlobal("_VERSION")) == "Lua 5.4");

    // Register a native function: add(a, b) -> a + b
    state.registerGlobal("add", (void* s, LuaValue[] args) {
        if (args.length < 2)
            return [luaNil()];
        long a = args[0].match!((long i) => i, (double d) => cast(long) d, _ => 0L);
        long b = args[1].match!((long i) => i, (double d) => cast(long) d, _ => 0L);
        return [LuaValue(a + b)];
    });

    auto addFn = state.getGlobal("add").match!((LuaFunction f) => f, _ => null);
    assert(addFn !is null);

    // Test successful pcall
    auto res = state.pcall(addFn, [LuaValue(10L), LuaValue(32L)]);
    assert(res.success);
    assert(res.results.length == 1);
    assert(res.results[0].match!((long i) => i == 42L, _ => false));

    // Register an error function
    state.registerGlobal("fail", (void* s, LuaValue[] args) {
        throw new LuaException("custom error occurred");
        return cast(LuaValue[])[];
    });
    auto failFn = state.getGlobal("fail").match!((LuaFunction f) => f, _ => null);

    // Test failing pcall catching LuaException
    auto failRes = state.pcall(failFn, []);
    assert(!failRes.success);
    assert(toLuaString(failRes.error) == "custom error occurred");

    writeln("  [PASS] testStateAndPCall");
}

int main() {
    writeln("Running dlua Foundation Unit Tests...");
    testTypes();
    testTable();
    testStateAndPCall();
    writeln("All Foundation Tests Passed Successfully!");
    return 0;
}
