/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Allocation-free entry points for the hottest built-in functions.
///
/// A `fastCall` reads its arguments straight from the caller's registers
/// (`regs[base + 1 .. base + n]`) and writes results from `regs[base]`, so the interpreter
/// needs no argument array, result array or call record. It must return -1 *before touching
/// anything* whenever the generic implementation could raise an error or take a path that is not
/// plain (metamethods, coercions, unusual arguments); the generic function then runs as usual.
/// Semantics must stay identical to the corresponding functions in `base`, `math`, `string` and
/// `table`.
module varis.lib.fastcall;

import varis.types;
import varis.table;
import varis.state;
import std.math : isNaN;
static import std.math;
static import core.stdc.math;

private static immutable size_t metatableNameHash = hashOf("__metatable");
private static immutable size_t gcNameHash = hashOf("__gc");
private static immutable size_t modeNameHash = hashOf("__mode");
private static immutable size_t pairsNameHash = hashOf("__pairs");

private bool absentOrNil(LuaTable table, string name, size_t hash) {
    auto slot = table.findStringHashed(name, hash);
    return slot is null || slot.isNil;
}

private int fastType(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1)
        return -1;
    r[base] = LuaValue(r[base + 1].typeName());
    return 1;
}

private int fastSelect(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1)
        return -1;
    auto selector = &r[base + 1];
    if (selector.isString) {
        auto text = selector.asString;
        if (text.length && text[0] == '#') {
            r[base] = LuaValue(cast(long)(n - 1));
            return 1;
        }
        return -1;
    }
    if (!selector.isInteger)
        return -1;
    long i = selector.asInteger;
    if (i < 1 || i > n)
        return -1;
    int count = n - cast(int) i;
    foreach (k; 0 .. count)
        r[base + k] = r[base + 1 + cast(int) i + k];
    return count;
}

private int fastRawget(void* sp, LuaValue[] r, int base, int n) {
    if (n < 2 || !r[base + 1].isTable)
        return -1;
    r[base] = r[base + 1].asTable.rawget(r[base + 2]);
    return 1;
}

private int fastRawset(void* sp, LuaValue[] r, int base, int n) {
    if (n < 3 || !r[base + 1].isTable)
        return -1;
    auto key = &r[base + 2];
    if (key.isNil || (key.isFloat && isNaN(key.asFloat)))
        return -1;
    r[base + 1].asTable.rawset(*key, r[base + 3]);
    r[base] = r[base + 1];
    return 1;
}

private int fastRawequal(void* sp, LuaValue[] r, int base, int n) {
    if (n < 2)
        return -1;
    r[base] = LuaValue(luaRawEqual(r[base + 1], r[base + 2]));
    return 1;
}

private int fastSetmetatable(void* sp, LuaValue[] r, int base, int n) {
    if (n < 2 || !r[base + 1].isTable)
        return -1;
    auto target = r[base + 1].asTable;
    auto meta = &r[base + 2];
    if (!meta.isNil && !meta.isTable)
        return -1;
    if (target.metatable !is null && !absentOrNil(target.metatable, "__metatable", metatableNameHash))
        return -1;
    if (meta.isTable) {
        auto handlers = meta.asTable;
        // Finalizers and weak tables need the generic bookkeeping.
        if (!absentOrNil(handlers, "__gc", gcNameHash) || !absentOrNil(handlers, "__mode", modeNameHash))
            return -1;
        target.metatable = handlers;
    } else
        target.metatable = null;
    r[base] = r[base + 1];
    return 1;
}

private int fastGetmetatable(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1 || !r[base + 1].isTable)
        return -1;
    auto meta = r[base + 1].asTable.metatable;
    if (meta is null) {
        r[base] = luaNil();
        return 1;
    }
    auto protection = meta.findStringHashed("__metatable", metatableNameHash);
    if (protection !is null && !protection.isNil)
        r[base] = *protection;
    else
        r[base] = LuaValue(meta);
    return 1;
}

private int fastAssert(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1 || !r[base + 1].isTruthy)
        return -1;
    foreach (k; 0 .. n)
        r[base + k] = r[base + 1 + k];
    return n;
}

private int fastNext(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1 || !r[base + 1].isTable)
        return -1;
    LuaValue key = n >= 2 ? r[base + 2] : luaNil();
    LuaValue nextKey, nextValue;
    int status = r[base + 1].asTable.nextFast(key, nextKey, nextValue);
    if (status < 0)
        return -1;
    if (status == 0) {
        r[base] = luaNil();
        return 1;
    }
    r[base] = nextKey;
    r[base + 1] = nextValue;
    return 2;
}

private int fastPairs(void* sp, LuaValue[] r, int base, int n) {
    auto state = cast(LuaState) sp;
    if (n < 1 || !r[base + 1].isTable || state.fastNext is null)
        return -1;
    auto meta = r[base + 1].asTable.metatable;
    if (meta !is null && !absentOrNil(meta, "__pairs", pairsNameHash))
        return -1;
    r[base] = LuaValue(state.fastNext);
    r[base + 2] = luaNil();
    return 3;
}

private int fastIpairs(void* sp, LuaValue[] r, int base, int n) {
    auto state = cast(LuaState) sp;
    if (n < 1 || state.fastIpairsIter is null)
        return -1;
    r[base] = LuaValue(state.fastIpairsIter);
    r[base + 2] = LuaValue(0L);
    return 3;
}

private LuaValue numberToInteger(double d) {
    long n;
    if (floatToInteger(d, n))
        return LuaValue(n);
    return LuaValue(d);
}

private int fastFloor(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1)
        return -1;
    auto v = &r[base + 1];
    if (v.isInteger) {
        r[base] = *v;
        return 1;
    }
    if (!v.isFloat)
        return -1;
    r[base] = numberToInteger(std.math.floor(v.asFloat));
    return 1;
}

private int fastCeil(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1)
        return -1;
    auto v = &r[base + 1];
    if (v.isInteger) {
        r[base] = *v;
        return 1;
    }
    if (!v.isFloat)
        return -1;
    r[base] = numberToInteger(std.math.ceil(v.asFloat));
    return 1;
}

private int fastSqrt(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1)
        return -1;
    auto v = &r[base + 1];
    if (v.isFloat)
        r[base] = LuaValue(core.stdc.math.sqrt(v.asFloat));
    else if (v.isInteger)
        r[base] = LuaValue(core.stdc.math.sqrt(cast(double) v.asInteger));
    else
        return -1;
    return 1;
}

private int fastAbs(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1)
        return -1;
    auto v = &r[base + 1];
    if (v.isInteger) {
        long i = v.asInteger;
        if (i < 0)
            i = cast(long)(0UL - cast(ulong) i);
        r[base] = LuaValue(i);
    } else if (v.isFloat)
        r[base] = LuaValue(std.math.fabs(v.asFloat));
    else
        return -1;
    return 1;
}

private int fastMin(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1)
        return -1;
    foreach (k; 1 .. n + 1)
        if (!r[base + k].isNumber)
            return -1;
    int best = 1;
    foreach (k; 2 .. n + 1)
        if (luaNumberLess(r[base + k], r[base + best]))
            best = k;
    r[base] = r[base + best];
    return 1;
}

private int fastMax(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1)
        return -1;
    foreach (k; 1 .. n + 1)
        if (!r[base + k].isNumber)
            return -1;
    int best = 1;
    foreach (k; 2 .. n + 1)
        if (luaNumberLess(r[base + best], r[base + k]))
            best = k;
    r[base] = r[base + best];
    return 1;
}

private size_t posRelatI(long pos, size_t len) {
    if (pos > 0)
        return cast(size_t) pos;
    if (pos == 0)
        return 1;
    if (pos < -cast(long) len)
        return 1;
    return len + cast(size_t) pos + 1;
}

private size_t endPosition(long pos, size_t len) {
    if (pos > cast(long) len)
        return len;
    if (pos >= 0)
        return cast(size_t) pos;
    if (pos < -cast(long) len)
        return 0;
    return len + cast(size_t) pos + 1;
}

private int fastStringLen(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1 || !r[base + 1].isString)
        return -1;
    r[base] = LuaValue(cast(long) r[base + 1].asString.length);
    return 1;
}

private int fastStringSub(void* sp, LuaValue[] r, int base, int n) {
    if (n < 2 || n > 3 || !r[base + 1].isString || !r[base + 2].isInteger)
        return -1;
    long last = -1;
    if (n == 3) {
        if (r[base + 3].isNil)
            last = -1;
        else if (r[base + 3].isInteger)
            last = r[base + 3].asInteger;
        else
            return -1;
    }
    string s = r[base + 1].asString;
    size_t start = posRelatI(r[base + 2].asInteger, s.length);
    size_t end = endPosition(last, s.length);
    r[base] = start > end ? LuaValue("") : LuaValue(s[start - 1 .. end]);
    return 1;
}

private int fastStringByte(void* sp, LuaValue[] r, int base, int n) {
    if (n < 1 || n > 2 || !r[base + 1].isString)
        return -1;
    string s = r[base + 1].asString;
    long position = 1;
    if (n == 2) {
        if (!r[base + 2].isInteger)
            return -1;
        position = r[base + 2].asInteger;
    }
    if (position < 1 || position > cast(long) s.length)
        return -1;
    r[base] = LuaValue(cast(long) cast(ubyte) s[cast(size_t) position - 1]);
    return 1;
}

private int fastTableInsert(void* sp, LuaValue[] r, int base, int n) {
    if (n != 2 || !r[base + 1].isTable)
        return -1;
    auto table = r[base + 1].asTable;
    if (table.metatable !is null)
        return -1;
    long next = cast(long)(cast(ulong) table.rawLen() + 1);
    table.rawset(LuaValue(next), r[base + 2]);
    return 0;
}

private void install(LuaFunction f, int function(void*, LuaValue[], int, int) fast) {
    if (f !is null)
        f.fastCall = fast;
}

private LuaFunction lookup(LuaTable table, string name) {
    if (table is null)
        return null;
    auto v = table.rawget(LuaValue(name));
    return v.isFunction ? v.asFunction : null;
}

/// Attaches the fast entry points to the freshly opened standard libraries of `state`.
void installFastCalls(LuaState state) {
    auto G = state.globals;
    install(lookup(G, "type"), &fastType);
    install(lookup(G, "select"), &fastSelect);
    install(lookup(G, "rawget"), &fastRawget);
    install(lookup(G, "rawset"), &fastRawset);
    install(lookup(G, "rawequal"), &fastRawequal);
    install(lookup(G, "setmetatable"), &fastSetmetatable);
    install(lookup(G, "getmetatable"), &fastGetmetatable);
    install(lookup(G, "assert"), &fastAssert);
    install(lookup(G, "next"), &fastNext);
    install(lookup(G, "pairs"), &fastPairs);
    install(lookup(G, "ipairs"), &fastIpairs);
    LuaTable library(string name) {
        auto v = G.rawget(LuaValue(name));
        return v.isTable ? v.asTable : null;
    }

    auto math = library("math");
    install(lookup(math, "floor"), &fastFloor);
    install(lookup(math, "ceil"), &fastCeil);
    install(lookup(math, "sqrt"), &fastSqrt);
    install(lookup(math, "abs"), &fastAbs);
    install(lookup(math, "min"), &fastMin);
    install(lookup(math, "max"), &fastMax);
    auto str = library("string");
    install(lookup(str, "len"), &fastStringLen);
    install(lookup(str, "sub"), &fastStringSub);
    install(lookup(str, "byte"), &fastStringByte);
    install(lookup(library("table"), "insert"), &fastTableInsert);
}
